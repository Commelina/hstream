{-# LANGUAGE RecordWildCards #-}

module HStream.Kafka.Common.Security where

import Data.Text (Text)
import qualified Data.Text as T

-- | A kafka principal. It is a 2-tuple of non-null type and non-null name.
--   For default authorizer, type is "User".
data Principal = Principal
  { principalType :: Text
  , principalName :: Text
  }
instance Show Principal where
  show Principal{..} =
    T.unpack principalType <> ":" <> T.unpack principalName
