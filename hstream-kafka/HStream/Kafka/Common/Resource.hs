{-# LANGUAGE RecordWildCards #-}

module HStream.Kafka.Common.Resource where

import Data.Text (Text)
import qualified Data.Text as T


--
class Matchable a where
  type FilterType a :: Type
  match :: a -> FilterType a -> Bool
  matchAtMostOne :: FilterType a -> Bool
  indefiniteFieldInFilter :: FilterType a -> Maybe Text

-- | A type of resource that can be applied to by an ACL, which is an 'Int8'
--   start from 0.
--   See org.apache.kafka.common.resource.ResourceType.
data ResourceType
  = Res_UNKNOWN
  | Res_ANY
  | Res_TOPIC
  | Res_GROUP
  | Res_CLUSTER
  | Res_TRANSACTIONAL_ID
  | Res_DELEGATION_TOKEN
  | Res_USER
  deriving (Eq, Enum, Ord)
instance Show ResourceType where
  show Res_UNKNOWN          = "UNKNOWN"
  show Res_ANY              = "ANY"
  show Res_TOPIC            = "TOPIC"
  show Res_GROUP            = "GROUP"
  show Res_CLUSTER          = "CLUSTER"
  show Res_TRANSACTIONAL_ID = "TRANSACTIONAL_ID"
  show Res_DELEGATION_TOKEN = "DELEGATION_TOKEN"
  show Res_USER             = "USER"

-- | A cluster resource which is a 2-tuple (type, name).
--   See org.apache.kafka.common.resource.Resource.
data Resource = Resource
  { resResourceType :: ResourceType
  , resResourceName :: Text
  }
instance Show Resource where
  show Resource{..} =
    "(resourceType=" <> show resResourceType <>
    ", name="        <> s_name               <> ")"
    where s_name = if T.null resResourceName then "<any>" else T.unpack resResourceName

-- [0..4]
-- | A resource pattern type, which is an 'Int8' start from 0.
--   WARNING: Be sure to understand the meaning of 'Pat_MATCH'.
--            A '(TYPE, "name", MATCH)' filter matches the following patterns:
--            1. All '(TYPE, "name", LITERAL)'
--            2. All '(TYPE, "*", LITERAL)'
--            3. All '(TYPE, "name", PREFIXED)'
--   See org.apache.kafka.common.resource.PatternType.
data PatternType
  = Pat_UNKNOWN
  | Pat_ANY
  | Pat_MATCH
  | Pat_LITERAL
  | Pat_PREFIXED
  deriving (Eq, Enum, Ord)
instance Show PatternType where
  show Pat_UNKNOWN  = "UNKNOWN"
  show Pat_ANY      = "ANY"
  show Pat_MATCH    = "MATCH"
  show Pat_LITERAL  = "LITERAL"
  show Pat_PREFIXED = "PREFIXED"

-- | A pattern used by ACLs to match resources.
--   See org.apache.kafka.common.resource.ResourcePattern.
data ResourcePattern = ResourcePattern
  { resPatResourceType :: ResourceType -- | Can not be 'Res_ANY'
  , resPatResourceName :: Text -- | Can not be null but can be 'WILDCARD' -- FIXME: which?
  , resPatPatternType  :: PatternType -- | Can not be 'Pat_ANY' or 'Pat_MATCH'
  }
instance Show ResourcePattern where
  show ResourcePattern{..} =
    "ResourcePattern(resourceType=" <> show resPatResourceType     <>
    ", name="                       <> T.unpack resPatResourceName <>
    ", patternType="                <> show resPatPatternType      <> ")"

-- | Orders by resource type, then pattern type, and finally REVERSE name
--   See kafka.security.authorizer.
instance Ord ResourcePattern where
  compare p1 p2 = compare (resPatResourceType p1) (resPatResourceType p2)
               <> compare (resPatPatternType  p1) (resPatPatternType  p2)
               <> compare (resPatResourceName p2) (resPatResourceName p1)

-- | A filter that can match 'ResourcePattern'.
--   See org.apache.kafka.common.resource.ResourcePatternFilter.
data ResourcePatternFilter = ResourcePatternFilter
  { resPatFilterResourceType :: ResourceType
    -- | The resource type to match. If 'Res_ANY', ignore the resource type.
    --   Otherwise, only match patterns with the same resource type.
  , resPatFilterResourceName :: Text
    -- | The resource name to match. If null, ignore the resource name.
    --   If 'WILDCARD', only match wildcard patterns. -- FIXME: which WILDCARD?
  , resPatFilterPatternType  :: PatternType
    -- | The resource pattern type to match.
    --   If 'Pat_ANY', match ignore the pattern type.
    --   If 'Pat_MATCH', see 'Pat_MATCH'.
    --   Otherwise, match patterns with the same pattern type.
  }
instance Show ResourcePatternFilter where
  show ResourcePatternFilter{..} =
    "ResourcePattern(resourceType=" <> show resPatFilterResourceType <>
    ", name="                       <> s_name                        <>
    ", patternType="                <> show resPatFilterPatternType  <> ")"
    where s_name = if T.null resPatFilterResourceName then "<any>" else T.unpack resPatFilterResourceName

instance Matchable ResourcePattern where
  type FilterType ResourcePattern = ResourcePatternFilter
  -- See org.apache.kafka.common.resource.ResourcePatternFilter#matches
  match ResourcePattern{..} ResourcePatternFilter{..}
    | resPatFilterResourceType /= Res_ANY && resPatResourceType /= resPatFilterResourceType = False
    | resPatFilterPatternType /= Pat_ANY &&
      resPatFilterPatternType /= Pat_MATCH &&
      resPatFilterPatternType /= resPatPatternType = False
    | T.null resPatFilterResourceName = True
    | resPatFilterPatternType == Pat_ANY ||
      resPatFilterPatternType == resPatPatternType = resPatFilterResourceName == resPatResourceName
    | otherwise = case resPatPatternType of
        Pat_LITERAL  -> resPatFilterResourceName == resPatResourceName || resPatResourceName == "*" -- FIXME: WILDCARD
        Pat_PREFIXED -> T.isPrefixOf resPatFilterResourceName resPatResourceName
        _            -> error "Unsupported PatternType: "  <> show resPatPatternType -- FIXME: exception
  matchAtMostOne = isNothing . indefiniteFieldInFilter
  indefiniteFieldInFilter ResourcePatternFilter{..} = do
    when (resPatFilterResourceType == Res_ANY) $ return "Resource type is ANY."
    when (resPatFilterResourceType == Res_UNKNOWN) $ return "Resource type is UNKNOWN."
    when (T.null resPatResourceName) $ return "Resource name is NULL."
    when (resPatFilterPatternType == Pat_MATCH) $ return "Resource pattern type is MATCH."
    when (resPatFilterPatternType == Pat_UNKNOWN) $ return "Resource pattern type is UNKNOWN."
    return Nothing

resourcePatternFromFilter :: ResourcePatternFilter -> Set.Set ResourcePattern
resourcePatternFromFilter ResourcePatternFilter{..} =
  case resPatFilterPatternType of
    Pat_LITERAL -> Set.singleton $ ResourcePattern
                                 { resPatResourceType = resPatFilterResourceType
                                 , resPatResourceName = resPatFilterResourceName
                                 , resPatPatternType  = resPatFilterPatternType
                                 }
    Pat_PREFIXED -> Set.singleton $ ResourcePattern
                                  { resPatResourceType = resPatFilterResourceType
                                  , resPatResourceName = resPatFilterResourceName
                                  , resPatPatternType  = resPatFilterPatternType
                                  }
    Pat_ANY -> Set.fromList [ ResourcePattern
                              { resPatResourceType = resPatFilterResourceType
                              , resPatResourceName = resPatFilterResourceName
                              , resPatPatternType  = Pat_LITERAL
                              }
                            , ResourcePattern
                              { resPatResourceType = resPatFilterResourceType
                              , resPatResourceName = resPatFilterResourceName
                              , resPatPatternType  = Pat_PREFIXED
                              }
                            ]
    _ -> error "Cannot determine matching resources for patternType "  <> show resPatFilterPatternType -- FIXME: exception
