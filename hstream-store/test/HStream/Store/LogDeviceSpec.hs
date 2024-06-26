module HStream.Store.LogDeviceSpec where

import           Data.List                        (sort)
import qualified Data.Map.Strict                  as Map
import           Test.Hspec
import           Z.Data.CBytes                    (CBytes)

import qualified HStream.Store                    as S
import qualified HStream.Store.Internal.LogDevice as I
import           HStream.Store.SpecUtils

spec :: Spec
spec = do
  loggroupSpec
  logdirSpec

logdirSpec :: Spec
logdirSpec = describe "LogDirectory" $ do
  let attrs = S.def{ I.logReplicationFactor = I.defAttr1 1
                   , I.logBacklogDuration = I.defAttr1 (Just 60)
                   , I.logScdEnabled = I.defAttr1 False
                   , I.logLocalScdEnabled = I.defAttr1 True
                   , I.logStickyCopySets = I.defAttr1 False
                   , I.logAttrsExtras = Map.fromList [("A", "B")]
                   }

  it "get log directory children name" $ do
    dirname <- ("/" <>) <$> newRandomName 10
    _ <- I.makeLogDirectory client dirname attrs False
    _ <- I.makeLogDirectory client (dirname <> "/A") attrs False
    version <- I.logDirectoryGetVersion =<< I.makeLogDirectory client (dirname <> "/B") attrs False
    I.syncLogsConfigVersion client version
    dir <- I.getLogDirectory client dirname
    names <- I.logDirChildrenNames dir
    sort names `shouldBe` ["A", "B"]
    I.logDirLogsNames dir `shouldReturn` []
    I.syncLogsConfigVersion client =<< I.removeLogDirectory client dirname True
    I.getLogDirectory client dirname `shouldThrow` anyException

  it "get log directory logs name" $ do
    let logid1 = 101
        logid2 = 102
    dirname <- ("/" <>) <$> newRandomName 10
    _ <- I.makeLogDirectory client dirname attrs False
    _ <- I.makeLogGroup client (dirname <> "/A") logid1 logid1 attrs False
    version <- I.logGroupGetVersion =<<
      I.makeLogGroup client (dirname <> "/B") logid2 logid2 attrs False
    I.syncLogsConfigVersion client version
    dir <- I.getLogDirectory client dirname
    names <- I.logDirLogsNames dir
    sort names `shouldBe` ["A", "B"]
    I.logDirChildrenNames dir `shouldReturn` []
    I.syncLogsConfigVersion client =<< I.removeLogDirectory client dirname True
    I.getLogDirectory client dirname `shouldThrow` anyException

  it "get log group and child directory" $ do
    let logid = 103
    dirname <- ("/" <>) <$> newRandomName 10
    _ <- I.makeLogDirectory client dirname attrs False
    _ <- I.makeLogDirectory client (dirname <> "/A") attrs False
    version <- I.logGroupGetVersion =<<
      I.makeLogGroup client (dirname <> "/B") logid logid attrs False
    I.syncLogsConfigVersion client version
    dir <- I.getLogDirectory client dirname
    nameA <- I.logDirectoryGetFullName =<< I.getLogDirectory client =<< I.logDirChildFullName dir "A"
    nameA `shouldBe` dirname <> "/A/"
    nameB <- I.logGroupGetFullName =<< I.getLogGroup client =<< I.logDirLogFullName dir "B"
    nameB `shouldBe` dirname <> "/B"
    I.syncLogsConfigVersion client =<< I.removeLogDirectory client dirname True
    I.getLogDirectory client dirname `shouldThrow` anyException

  let attrs_ra = S.def{ I.logReplicateAcross = I.defAttr1 [(S.NodeLocationScope_DATA_CENTER, 3)] }
  logdirAround attrs_ra $ it "attributes: logReplicateAcross" $ \dirname -> do
    dir <- I.getLogDirectory client dirname
    attrs_got <- I.logDirectoryGetAttrs dir
    S.logReplicateAcross attrs_got `shouldBe` I.defAttr1 [(S.NodeLocationScope_DATA_CENTER, 3)]

  it "Loggroup's attributes should be inherited by the parent directory" $ do
    dirname <- ("/" <>) <$> newRandomName 10
    let logid = 104
        lgname = dirname <> "/A"
    _ <- I.makeLogDirectory client dirname attrs False
    I.syncLogsConfigVersion client =<< I.logGroupGetVersion
                                   =<< I.makeLogGroup client lgname logid logid S.def False
    lg <- I.getLogGroup client lgname
    attrs' <- I.logGroupGetAttrs lg
    I.logReplicationFactor attrs' `shouldBe` I.Attribute (Just 1) True
    I.logBacklogDuration attrs' `shouldBe` I.Attribute (Just (Just 60)) True
    Map.lookup "A" (I.logAttrsExtras attrs') `shouldBe` Just "B"
    I.logScdEnabled attrs' `shouldBe` I.Attribute (Just False) True
    I.logLocalScdEnabled attrs' `shouldBe` I.Attribute (Just True) True
    I.logStickyCopySets attrs' `shouldBe` I.Attribute (Just False) True
    I.syncLogsConfigVersion client =<< I.removeLogDirectory client dirname True

loggroupAround' :: SpecWith (CBytes, S.C_LogID) -> Spec
loggroupAround' =
  let attrs = S.def{ I.logReplicationFactor = I.defAttr1 1
                   , I.logBacklogDuration = I.defAttr1 (Just 60)
                   , I.logSingleWriter = I.defAttr1 True
                   , I.logSyncReplicationScope = I.defAttr1 S.NodeLocationScope_DATA_CENTER
                   , I.logScdEnabled = I.defAttr1 False
                   , I.logLocalScdEnabled = I.defAttr1 True
                   , I.logStickyCopySets = I.defAttr1 False
                   , I.logAttrsExtras = Map.fromList [("A", "B")]
                   }
      logid = 105
      logname = "LogDeviceSpec_LogGroupSpec"
   in loggroupAround logid logname attrs

loggroupSpec :: Spec
loggroupSpec = describe "LogGroup" $ loggroupAround' $ parallel $ do
  it "log group get attrs" $ \(lgname, _logid) -> do
    lg <- I.getLogGroup client lgname
    attrs' <- I.logGroupGetAttrs lg
    I.logReplicationFactor attrs' `shouldBe` I.defAttr1 1
    I.logBacklogDuration attrs' `shouldBe` I.defAttr1 (Just 60)
    I.logSingleWriter attrs' `shouldBe` I.defAttr1 True
    I.logScdEnabled attrs' `shouldBe` I.defAttr1 False
    I.logLocalScdEnabled attrs' `shouldBe` I.defAttr1 True
    I.logStickyCopySets attrs' `shouldBe` I.defAttr1 False
    I.logSyncReplicationScope attrs' `shouldBe` I.defAttr1 S.NodeLocationScope_DATA_CENTER
    Map.lookup "A" (I.logAttrsExtras attrs') `shouldBe` Just "B"

  it "log group get and set range" $ \(lgname, logid) -> do
    let logid' = logid + 1
    lg <- I.getLogGroup client lgname
    I.logGroupGetRange lg `shouldReturn`(logid, logid)
    I.syncLogsConfigVersion client =<< I.logGroupSetRange client lgname (logid',logid')
    range' <- I.logGroupGetRange =<< I.getLogGroup client lgname
    range' `shouldBe` (logid', logid')

  it "get a nonexist loggroup should throw NOTFOUND" $ \(_, _) -> do
    I.getLogGroup client "this_is_a_non_exist_logroup" `shouldThrow` S.isNOTFOUND

  it "delete a nonexist loggroup should throw NOTFOUND" $ \(_, _) -> do
    I.removeLogGroup client "this_is_a_non_exist_logroup" `shouldThrow` S.isNOTFOUND
