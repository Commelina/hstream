{-# LANGUAGE RecordWildCards #-}

module HStream.Kafka.Common.Acl where

import Data.Text (Text)
import qualified Data.Text as T

import HStream.Kafka.Common.Resource

-- [0..14]
data AclOperation
  = AclOp_UNKNOWN
  | AclOp_ANY
  | AclOp_ALL
  | AclOp_READ
  | AclOp_WRITE
  | AclOp_CREATE
  | AclOp_DELETE
  | AclOp_ALTER
  | AclOp_DESCRIBE
  | AclOp_CLUSTER_ACTION
  | AclOp_DESCRIBE_CONFIGS
  | AclOp_ALTER_CONFIGS
  | AclOp_IDEMPOTENT_WRITE
  | AclOp_CREATE_TOKENS
  | AclOp_DESCRIBE_TOKENS
  deriving (Eq, Enum, Show)
-- FIXME: Show

-- [0..3]
data AclPermissionType
  = AclPerm_UNKNOWN
  | AclPerm_ANY -- used in filter
  | AclPerm_DENY
  | AclPerm_ALLOW
  deriving (Eq, Enum, Show)
-- FIXME: Show

-- | Data of an access control entry (ACE), which is a 4-tuple of principal,
--   host, operation and permission type.
--   Used in both 'AccessControlEntry' and 'AccessControlEntryFilter',
--   with slightly different field requirements.
data AccessControlEntryData = AccessControlEntryData
  { aceDataPrincipal      :: Text
  , aceDataHost           :: Text
  , aceDataOperation      :: AclOperation
  , aceDataPermissionType :: AclPermissionType
  }
instance Show AccessControlEntryData where
  show AccessControlEntryData{..} =
    "(principal="       <> s_principal                <>
    ", host="           <> s_host                     <>
    ", operation="      <> show aceDataOperation      <>
    ", permissionType=" <> show aceDataPermissionType <> ")"
    where s_principal = if T.null aceDataPrincipal then "<any>" else T.unpack aceDataPrincipal
          s_host      = if T.null aceDataHost      then "<any>" else T.unpack aceDataHost

-- | An access control entry (ACE).
--   Requirements: principal and host can not be null.
--                 operation can not be 'AclOp_ANY'.
--                 permission type can not be 'AclPerm_ANY'.
newtype AccessControlEntry = AccessControlEntry
  { aceData :: AccessControlEntryData
  }
instance Show AccessControlEntry where
  show AccessControlEntry{..} = show aceData

-- | A filter which matches access control entry(ACE)s.
--   Requirements: principal and host can both be null.
newtype AccessControlEntryFilter = AccessControlEntryFilter
  { aceFilterData :: AccessControlEntryData
  }
instance Show AccessControlEntryFilter where
  show AccessControlEntryFilter{..} = show aceFilterData

instance Matchable AccessControlEntry where
  type FilterType AccessControlEntry = AccessControlEntryFilter
  -- See org.apache.kafka.common.acl.AccessControlEntryFilter#matches
  match AccessControlEntry{..} AccessControlEntryFilter{..}
    | not (T.null (aceDataPrincipal aceFilterData)) &&
      aceDataPrincipal aceFilterData /= aceDataPrincipal aceData = False
    | not (T.null (aceDataHost aceFilterData)) &&
      aceDataHost aceFilterData /= aceDataHost aceData = False
    | aceDataOperation aceFilterData /= AclOp_ANY &&
      aceDataOperation aceFilterData /= aceDataOperation aceData = False
    | otherwise = aceDataPermissionType aceFilterData == AclPerm_ANY ||
                  aceDataPermissionType aceFilterData == aceDataPermissionType aceData
  matchAtMostOne = isNothing . indefiniteFieldInFilter
  indefiniteFieldInFilter AccessControlEntryFilter{ aceFilterData = AccessControlEntryData{..} } = do
    when (T.null aceDataPrincipal) $ return "Principal is NULL"
    when (T.null aceDataHost)      $ return "Host is NULL"
    when (aceDataOperation == AclOp_ANY) $ return "Operation is ANY"
    when (aceDataOperation == AclOp_UNKNOWN) $ return "Operation is UNKNOWN"
    when (aceDataPermissionType == AclPerm_ANY) $ return "Permission type is ANY"
    when (aceDataPermissionType == AclPerm_UNKNOWN) $ return "Permission type is UNKNOWN"
    return Nothing

-- | A binding between a resource pattern and an access control entry (ACE).
data AclBinding = AclBinding
  { aclBindingResourcePattern :: ResourcePattern
  , aclBindingACE             :: AccessControlEntry
  }
instance Show AclBinding where
  show AclBinding{..} =
    "(pattern=" <> show aclBindingResourcePattern <>
    ", entry="  <> show aclBindingACE             <> ")"

-- | A filter which can match 'AclBinding's.
data AclBindingFilter = AclBindingFilter
  { aclBindingFilterResourcePatternFilter :: ResourcePatternFilter
  , aclBindingFilterACEFilter             :: AccessControlEntryFilter
  }
instance Show AclBindingFilter where
  show AclBindingFilter{..} =
    "(patternFilter=" <> show aclBindingFilterResourcePatternFilter <>
    ", entryFilter="  <> show aclBindingFilterACEFilter             <> ")"

instance Matchable AclBinding where
  type FilterType AclBinding = AclBindingFilter
  -- See org.apache.kafka.common.acl.AclBindingFilter#matches
  match AclBinding{..} AclBindingFilter{..} =
    match aclBindingResourcePattern aclBindingFilterResourcePatternFilter &&
    match aclBindingACE             aclBindingFilterACEFilter
  matchAtMostOne AclBindingFilter{..} =
    matchAtMostOne aclBindingFilterResourcePatternFilter &&
    matchAtMostOne aclBindingFilterACEFilter
  indefiniteFieldInFilter AclBindingFilter{..} = do
    indefiniteFieldInFilter aclBindingFilterResourcePatternFilter
    indefiniteFieldInFilter aclBindingFilterACEFilter = do
      indefiniteFieldInFilter aclBindingFilterResourcePatternFilter
      indefiniteFieldInFilter aclBindingFilterACEFilter

-- TODO: validate
-- 1. No UNKNOWN contained
-- 2. resource pattern does not contain '/'
validateAclBinding :: AclBinding -> Either String ()
validateAclBinding AclBinding{..} = undefined
