{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

module Language.SQL.Codegen where

import Language.SQL.AST
import Language.SQL.Parse
import Language.SQL.Validatable
import Language.SQL.Extra

import Data.Aeson
import qualified Data.HashMap.Strict as HM

import Data.Maybe
import Control.Comonad ((=>>))
import HStream.Processor
import HStream.Processor.Internal
import HStream.Topic
import RIO

import qualified RIO.ByteString.Lazy as BL
import System.Random
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Prelude as P

import Data.Scientific
import Data.Text (pack)

-- SELECT temperature, humidity FROM sss WHERE temperature >= 40;

run :: Text -> IO ()
run input = do
  let task = codegen input
  mockStore <- mkMockTopicStore
  mp  <- mkMockTopicProducer mockStore
  mc' <- mkMockTopicConsumer mockStore

  async . forever $ do
    threadDelay 1000000
    MockMessage {..} <- mkMockData
    send mp RawProducerRecord { rprTopic = "demo-source"
                              , rprKey = mmKey
                              , rprValue = mmValue
                              }

  mc <- subscribe mc' ["demo-sink"]

  async . forever $ do
    records <- pollRecords mc 1000000
    forM_ records $ \RawConsumerRecord {..} ->
      P.putStr "detect abnormal data: " >> BL.putStrLn rcrValue

  logOptions <- logOptionsHandle stderr True

  withLogFunc logOptions $ \lf -> do
    let taskConfig =
          TaskConfig
            { tcMessageStoreType = Mock mockStore,
              tcLogFunc = lf
            }
    runTask taskConfig task

--------------------------------------------------------------------------------
genTaskFromSQL :: Text -> Either String Task
genTaskFromSQL input = do
  let toks = tokens $ preprocess input
  sql' <- pSQL toks
  sql  <- validate sql'
  case sql of
    QSelect _ select@(DSelect _ sel frm whr _ _) ->
      let src = genStreamFromFrm frm
       in return . build $ buildTask "demo"
            =>> addSource (genSourceConfig select)
            =>> addProcessor "filter" (filterProcessor $ genFilterRFromWhr whr) [src]
            =>> addProcessor "map" (mapProcessor $ genMapRFromSel sel) ["filter"]
            =>> addSink (genSinkConfig select) ["map"]
    QCreate pos _ -> Left $ errGenWithPos pos "Task can only be generated from SELECT query"
    QInsert pos _ -> Left $ errGenWithPos pos "Task can only be generated from SELECT query"

codegen :: Text -> Task
codegen input =
  let task' = genTaskFromSQL input
   in case task' of
        Left err   -> error err
        Right task -> task

--------------------------------------------------------------------------------
-- Sel
genPairFromExpr :: ValueExpr LineCol -> Object -> Either String (Text, Value)
genPairFromExpr (ExprColName _ (ColNameSimple _ (Ident t))) o = return (t, getFieldByName o t)
genPairFromExpr (ExprColName _ (ColNameStream pos _ _)) _ = Left $ errGenWithPos pos "Column name with stream is not supported yet"
genPairFromExpr (ExprColName _ (ColNameInner pos _ _))  _ = Left $ errGenWithPos pos "Nested column name is not supported yet"
genPairFromExpr (ExprColName _ (ColNameIndex pos _ _))  _ = Left $ errGenWithPos pos "Nested column name is not supported yet"
genPairFromExpr (ExprInt _ n)    _ = return (pack . show $ n, Number $ scientific n 0)
genPairFromExpr (ExprNum _ n)    _ = return (pack . show $ n, Number $ fromFloatDigits n)
genPairFromExpr (ExprString _ s) _ = return (pack s, String . pack $ s)
genPairFromExpr _ _ = Left $ errGenWithPos Nothing "Only column name and constant value expressions are supported yet"

genPairFromDCol :: DerivedCol LineCol -> Object -> Either String (Text, Value)
genPairFromDCol (DerivedColSimpl _ expr) o = genPairFromExpr expr o
genPairFromDCol (DerivedColAs _ expr (Ident t)) o = do
  (_, v) <- genPairFromExpr expr o
  return (t, v)

genObjectFromSel :: Sel LineCol -> Object -> Either String Object
genObjectFromSel (DSel _ (SelListAsterisk _)) o = return o
genObjectFromSel (DSel _ (SelListSublist _ dcols)) o = do
  pairs <- mapM (flip genPairFromDCol o) dcols
  return $ HM.fromList pairs

genMapRFromSel :: Sel LineCol -> Record Void Object -> Record Void Object
genMapRFromSel sel r@Record {..} =
  let o' = genObjectFromSel sel recordValue
   in case o' of
        Left err -> error err
        Right o  -> r { recordValue = o }

-- Frm
genStreamFromRefs :: LineCol -> [TableRef LineCol] -> Either String Text
genStreamFromRefs _ [(TableRefSimple _ (Ident t))] = return t
genStreamFromRefs _ [(TableRefAs pos _ _)] = Left $ errGenWithPos pos "FROM does not support stream aliases yet"
genStreamFromRefs _ [(TableRefJoin pos _ _ _ _ _)] = Left $ errGenWithPos pos "FROM does not support joining yet"
genStreamFromRefs pos [] = Left $ errGenWithPos pos "FROM has no stream name"
genStreamFromRefs pos _  = Left $ errGenWithPos pos "FROM does not support more than one streams yet"

genStreamFromFrm :: From LineCol -> Text
genStreamFromFrm (DFrom pos refs) =
  let t' = genStreamFromRefs pos refs
   in case t' of
        Left err -> error err
        Right t  -> t

-- Whr
genBoolFromSearchCond :: SearchCond LineCol -> Object -> Either String Bool
genBoolFromSearchCond (CondOp _ expr1 op expr2) o = do
  (_, v1) <- genPairFromExpr expr1 o
  (_, v2) <- genPairFromExpr expr2 o
  case op of
    CompOpEQ _    -> return $ v1 == v2
    CompOpNE _    -> return $ v1 /= v2
    CompOpLT pos  -> do
      ordering <- compareValue pos v1 v2
      case ordering of
        LT -> return True
        _  -> return False
    CompOpGT pos  -> do
      ordering <- compareValue pos v1 v2
      case ordering of
        GT -> return True
        _  -> return False
    CompOpLEQ pos -> do
      ordering <- compareValue pos v1 v2
      case ordering of
        GT -> return False
        _  -> return True
    CompOpGEQ pos -> do
      ordering <- compareValue pos v1 v2
      case ordering of
        LT -> return False
        _  -> return True
genBoolFromSearchCond (CondOr _ c1 c2) o = do
  b1 <- genBoolFromSearchCond c1 o
  b2 <- genBoolFromSearchCond c2 o
  return $ b1 || b2
genBoolFromSearchCond (CondAnd _ c1 c2) o = do
  b1 <- genBoolFromSearchCond c1 o
  b2 <- genBoolFromSearchCond c2 o
  return $ b1 && b2
genBoolFromSearchCond (CondNot _ c) o = do
  b <- genBoolFromSearchCond c o
  return $ not b
genBoolFromSearchCond (CondBetween pos e1 e e2) o = do
  (_, v1) <- genPairFromExpr e1 o
  (_, v)  <- genPairFromExpr e  o
  (_, v2) <- genPairFromExpr e2 o
  ordering1 <- compareValue pos v1 v
  ordering2 <- compareValue pos v v2
  case ordering1 of
    GT -> return False
    _  -> case ordering2 of
            GT -> return False
            _  -> return True

genFilterRFromWhr :: Where LineCol -> Record Void Object -> Bool
genFilterRFromWhr (DWhereEmpty _) _ = True
genFilterRFromWhr (DWhere _ cond) r@Record {..} =
  let b' = genBoolFromSearchCond cond recordValue
   in case b' of
        Left err -> error err
        Right b  -> b

--------------------------------------------------------------------------------
genSourceConfig :: Select LineCol -> SourceConfig Void Object
genSourceConfig (DSelect _ _ frm _ _ _) =
  let src = genStreamFromFrm frm
   in SourceConfig
      { sourceName = src
      , sourceTopicName = "demo-source"
      , keyDeserializer = voidDeserializer
      , valueDeserializer = Deserializer (\s -> (fromJust $ decode s) :: Object)
      }

genSinkConfig :: Select LineCol -> SinkConfig Void Object
genSinkConfig _ =
  SinkConfig
  { sinkName = "sink"
  , sinkTopicName = "demo-sink"
  , keySerializer = voidSerializer
  , valueSerializer = Serializer (encode :: Object -> BL.ByteString)
  }

--------------------------------------------------------------------------------
getFieldByName :: Object -> Text -> Value
getFieldByName = (HM.!)

compareValue :: LineCol -> Value -> Value -> Either String Ordering
compareValue _ (Number x1) (Number x2) = return $ x1 `compare` x2
compareValue _ (String x1) (String x2) = return $ x1 `compare` x2
compareValue pos _ _ = Left $ errGenWithPos pos "Value does not support comparison"

--------------------------------------------------------------------------------
filterProcessor :: (Typeable k, Typeable v) => (Record k v -> Bool) -> Processor k v
filterProcessor f = Processor $ \r ->
  when (f r) $ forward r

mapProcessor :: (Typeable k, Typeable v, Typeable k', Typeable v') => (Record k v -> Record k' v') -> Processor k v
mapProcessor f = Processor $ forward . f

mkMockData :: IO MockMessage
mkMockData = do
  k <- getStdRandom (randomR (1, 10)) :: IO Int
  t <- getStdRandom (randomR (0, 100))
  h <- getStdRandom (randomR (0, 100))
  let r = HM.fromList [ ("temperature", Number $ scientific t 0), ("humidity", Number $ scientific h 0) ] :: HM.HashMap Text Value
  P.putStrLn $ "gen data: " ++ show r
  return
    MockMessage
      { mmTimestamp = 0,
        mmKey = Just $ TLE.encodeUtf8 $ TL.pack $ show k,
        mmValue = encode r
      }
