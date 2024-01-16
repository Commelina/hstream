module HStream.Kafka.Common.Authorizer where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

data AclEntry = AclEntry
  { aclEntryPrincipal :: Principal
  , aclEntryHost      :: Text
  , aclEntryOperation :: AclOperation
  , aclEntryPermissionType :: AclPermissionType
  }
instance Show AclEntry where
  show AclEntry{..} =
    s_principal                                                   <>
    " has "                        <> show aclEntryPermissionType <>
    " permission for operations: " <> show aclEntryOperation      <>
    " from hosts: "                <> s_host
    where s_principal = show aclEntryPrincipal
          s_host      = T.unpack aclEntryHost

aceToAclEntry :: AccessControlEntry -> AclEntry
aceToAclEntry AccessControlEntry{ aceData = AccessControlEntryData{..} } =
  AclEntry{..}
  where aclEntryPrincipal      = aceDataPrincipal
        aclEntryHost           = aceDataHost
        aclEntryOperation      = aceDataOperation
        aclEntryPermissionType = aceDataPermissionType

aclEntryToAce :: AclEntry -> AccessControlEntry
aclEntryToAce AclEntry{..} =
  AccessControlEntry{ aceData = AccessControlEntryData{..} }
  where aceDataPrincipal      = aclEntryPrincipal
        aceDataHost           = aclEntryHost
        aceDataOperation      = aclEntryOperation
        aceDataPermissionType = aclEntryPermissionType
----
type Acls = Set.Set AclEntry

data AclCache = AclCache
  { aclCacheAcls      :: Map.Map ResourcePattern Acls
  , aclCacheResources :: Map.Map (AccessControlEntry,ResourceType,PatternType)
                                 (Set.Set Text)
  }


getAcls :: AclCache -> AclBindingFilter -> [AclBinding]
getAcls AclCache{..} aclFilter =
  Map.foldrWithKey' f [] aclCacheAcls
  where
    f resPat acls acc =
      let g aclEntry acc' =
            let thisAclBinding = AclBinding resPat (aclEntryToAce aclEntry)
             in if match thisAclBinding aclFilter
                then acc' ++ [thisAclBinding]
                else acc'
       in Set.foldr' g acc acls

deleteAcls :: AclCache -> [AclBindingFilter] -> IO [K.ErrorCode]
deleteAcls AclCache{..} filters =
  let possibleResources = Map.keys aclCacheAcls <>
                          concatMap resourcePatternFromFilter (filter matchAtMostOne filters)
      resourcesToUpdate =
        Map.fromList $
        L.filter (\(_,fs) -> not (L.null fs)) $
        L.map (\res ->
                  let matchedFilters = L.filter (\x -> match (res (aclBindingFilterResourcePatternFilter x))) filters
                   in (res, matchedFilters)
              ) possibleResources
  forM (Map.toList resourcesToUpdate) $ \(res,fs) -> do



updateResourceAcls :: ResourcePattern -> (Acls -> Acls) -> IO Bool
updateResourceAcls resPat f = do
  cache <- undefined
  curAcls <- case Map.lookup resPat (aclCacheAcls cache) of
    Nothing   -> undefined -- load from ZK
    Just acls -> acls
  newAcls <- go curAcls 0
  when (oldAcls /= newAcls) $ do
    -- update cache
    undefined
  where
    go oldAcls retries
      | retries <= 5 = do -- FIXME: max retries
          let newAcls = f oldAcls
          try $ if Set.null newAcls then do
            Log.debug $ "Deleting path for " <> show resPat <> " because it had no ACLs remaining"
            undefined -- delete from ZK
            return newAcls
            else do
            undefined -- update
            return newAcls
          >>= \case
            Left e -> do
              -- FIXME: log
              go oldAcls (retries + 1)
            Right acls_ -> return acls_
      | otherwise = do
          -- FIXME: log
          undefined


updateCache :: AclCache -> ResourcePattern -> Acls -> AclCache
updateCache cache resPat@ResourcePattern{..} acls =
  let curAces = maybe Set.empty (Set.map aclEntryToAce) (Map.lookup resPat (aclCacheAcls cache))
      newAces = Set.map aclEntryToAce acls
      acesToAdd    = Set.difference newAces curAces
      acesToRemove = Set.difference curAces newAces
   in let cacheResAfterAdd =
            Set.foldr' (\ace acc ->
              let key = (ace,resPatResourceType,resPatPatternType)
               in Map.insertWith Set.union key (Set.singleton resPatResourceName) acc
                       ) aclCacheResources acesToAdd
          cacheResAfterRemove =
            Set.foldr' (\ace acc ->
              let key = (ace,resPatResourceType,resPatPatternType)
               in Map.update (\x -> if x == Set.singleton resPatResourceName then Nothing else Just (Set.delete resPatResourceName x)) key acc
                       ) cacheResAfterAdd acesToRemove
       in let newAcls = if Set.null acls
                        then Map.delete resPat aclCacheAcls
                        else Map.insert resPat acls aclCacheAcls
           in AclCache newAcls cacheResAfterRemove
