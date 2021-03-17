{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeOperators     #-}

import           Data.ByteString                  (ByteString)
import           Data.Maybe                       (fromMaybe)
import           GHC.Generics                     (Generic)
import           Network.GRPC.HighLevel.Generated (GRPCMethodType (..),
                                                   Host (..), Port (..),
                                                   ServerRequest (..),
                                                   ServerResponse (..),
                                                   StatusCode (..),
                                                   defaultServiceOptions,
                                                   serverHost, serverPort)
import           Options.Generic

import           HStream.Broker.API

data Args = Args
  { bind :: Maybe ByteString <?> "grpc endpoint hostname (default \"localhost\")"
  , port :: Maybe Int        <?> "grpc endpoint port (default 50051)"
  } deriving (Generic, Show)
instance ParseRecord Args

connect :: ServerRequest 'Normal CommandConnect CommandConnected
        -> IO (ServerResponse 'Normal CommandConnected)
connect (ServerNormalRequest _meta (CommandConnect clientVer clientProtocolVer)) = do
  return (ServerNormalResponse (CommandConnected "1.0.0" 3) mempty StatusOk "")

main :: IO ()
main = do
  Args{..} <- getRecord "Runs the echo service"
  let opts = defaultServiceOptions
             { serverHost = Host . fromMaybe "localhost" . unHelpful $ bind
             , serverPort = Port . fromMaybe 50051       . unHelpful $ port
             }
  hstreamBrokerServer HStreamBroker{ hstreamBrokerConnect = connect } opts
