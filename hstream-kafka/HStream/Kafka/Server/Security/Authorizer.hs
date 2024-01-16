{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}

module HStream.Kafka.Server.Security.Authorizer where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Kind (Type)

import qualified Kafka.Protocol.Error as K

data AclAction = AclAction
  { aclActionResPat :: ResourcePattern
  , aclActionOp     :: AclOperation
  --, aclActionLogIfAllowed :: Bool
  --, more...
  }

data AuthorizationResult
  = Authz_ALLOWED
  | Authz_DENIED
  deriving (Eq, Enum, Show)

class Authorizer s :: Type where
  -- | Create new ACL bindings.
  createAcls :: s -> [AclBinding] -> IO [K.ErrorCode]

  -- | Remove matched ACL bindings.
  deleteAcls :: s -> [AclBindingFilter] -> IO [K.ErrorCode]

  -- | Get matched ACL bindings
  getAcls :: s -> AclBindingFilter -> IO [AclBinding]

  -- | Get the current number of ACLs. Return -1 if not implemented.
  aclCount :: s -> Int

  -- | Authorize the specified actions.
  authorize :: s -> [AclAction] -> IO [AuthorizationResult]
