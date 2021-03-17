{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeOperators     #-}

import           Control.Monad
import           Data.ByteString                  (ByteString)
import           Data.Maybe                       (fromMaybe)
import           HStream.Broker.API
import           GHC.Generics                     (Generic)
import           Network.GRPC.HighLevel.Client
import           Network.GRPC.LowLevel
import           Options.Generic
import           Prelude                          hiding (FilePath)

data Args = Args
  { bind       :: Maybe ByteString <?> "grpc endpoint hostname (default \"localhost\")"
  , port       :: Maybe Int        <?> "grpc endpoint port (default 50051)"
  } deriving (Generic, Show)
instance ParseRecord Args

main :: IO ()
main = do
  Args{..} <- getRecord "Runs the client"
  let
    rqt      = CommandConnect "1.0.1" 2
    cfg      = ClientConfig
                 (Host . fromMaybe "localhost" . unHelpful $ bind)
                 (Port . fromMaybe 50051       . unHelpful $ port)
                 [] Nothing Nothing
  withGRPC $ \g -> withClient g cfg $ \c -> do
    HStreamBroker{..} <- hstreamBrokerClient c
    hstreamBrokerConnect (ClientNormalRequest rqt 5 mempty) >>= \case
      ClientNormalResponse rsp _ _ StatusOk _ ->
        putStrLn $ "echo-client success: sent " ++ show rqt ++ " got " ++ show rsp
      ClientNormalResponse _ _ _ st _ -> fail $ "Got unexpected status " ++ show st ++ " from call, expecting StatusOk"
      ClientErrorResponse e           -> fail $ "Got client error: " ++ show e
