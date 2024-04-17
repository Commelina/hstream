module HStream.Common.Server.Lookup
  ( KafkaResource (..)
  , lookupKafka
  , lookupKafkaPersist

    -- * Internals
  , lookupNode
  , lookupNodePersist

  , kafkaResourceMetaId

  , lookupNodePersistWithCache
  , lookupKafkaPersistWithCache
  ) where

import           Control.Concurrent.STM
import           Control.Exception                (SomeException (..), throwIO,
                                                   try)
import           Data.List                        (find)
import           Data.Text                        (Text)
import qualified Data.Vector                      as V

import           HStream.Common.ConsistentHashing (getResNode)
import           HStream.Common.Server.HashRing   (LoadBalanceHashRing)
import           HStream.Common.Server.MetaData   (TaskAllocation (..))
import           HStream.Common.Types             (fromInternalServerNodeWithKey)
import qualified HStream.Exception                as HE
import           HStream.Gossip                   (GossipContext, getMemberList)
import qualified HStream.Logger                   as Log
import qualified HStream.MetaStore.Types          as M
import qualified HStream.Server.HStreamApi        as A

import qualified Data.Map.Strict as Map
import Data.IORef
import Control.Monad
import Control.Concurrent (threadDelay, forkIO)
import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent.MVar
import Data.Functor ((<&>))
import Data.Word

-- (key, metaId, advertisedListenersKey)
newtype ResourceAllocationKey = ResourceAllocationKey (Text, Text, Maybe Text)
  deriving (Eq, Show, Ord)
-- (epoch, nodeId, version)
newtype ResourceAllocationValue = ResourceAllocationValue (Word32, Word32, Int)

data ResourceAllocationCacheItem = ResourceAllocationCacheItem
  { racItemValue   :: ResourceAllocationValue
  , racItemIsValid :: IORef Bool
  , racItemDelayer :: MVar ()
  }

resourceAllocationCacheTimeout :: Int
resourceAllocationCacheTimeout = 2000 -- ms

newtype ResourceAllocationCache = ResourceAllocationCache
  { racMap :: IORef (Map.Map ResourceAllocationKey ResourceAllocationCacheItem)
  }

resourceAllocationCache :: ResourceAllocationCache
resourceAllocationCache = ResourceAllocationCache
  { racMap = unsafePerformIO $ newIORef Map.empty
  }
{-# NOINLINE resourceAllocationCache #-}

data ResourceAllocationCacheStatus
  = CACHE_VALID
  | CACHE_DELETED
  | CACHE_MODIFIED
  | CACHE_REFRESHED
  | CACHE_MISS
  deriving (Eq, Show, Enum)

-- WARNING: This function does not update cache. Do not forget to do that
--          in the real "lookup" function!
getResourceAllocationWithCache
  :: M.MetaHandle
  -> Text
  -> Text
  -> Maybe Text
  -> IO ( ResourceAllocationCacheStatus
        , Maybe ResourceAllocationValue
        )
getResourceAllocationWithCache metaHandle key metaId advertisedListenersKey = do
  let racKey = ResourceAllocationKey (key, metaId, advertisedListenersKey)
  readIORef (racMap resourceAllocationCache) <&> Map.lookup racKey >>= \case
    Just ResourceAllocationCacheItem{..} -> do
      readIORef racItemIsValid >>= \case
        True  -> return (CACHE_VALID, Just racItemValue) -- (alive->do not refresh cache; otherwise->refresh*delay) CACHE_VALID
        -- CACHE_DELETED/CACHE_MODIFIED/CACHE_REFRESHED
        False -> do
          meta_m <- getResourceAllocation metaId metaHandle -- should refresh cache (nil->delete; same->reset_timeout; diff->reset_timeout&delay)
          case meta_m of
            Nothing -> return (CACHE_DELETED, Nothing)
            Just v  -> do
              let (ResourceAllocationValue (_,nodeId_old,_)) = racItemValue
                  (ResourceAllocationValue (_,nodeId_new,_)) = v
              if nodeId_old == nodeId_new
                then return (CACHE_REFRESHED, Just v)
                else return (CACHE_MODIFIED , Just v)
    Nothing -> do
      -- CACHE_MISS
      meta_m <- getResourceAllocation metaId metaHandle -- new allocate
      return (CACHE_MISS, meta_m)
  where
    getResourceAllocation metaId_ metaHandle_ =
      M.getMetaWithVer @TaskAllocation metaId_ metaHandle_ >>= \case
        Just (TaskAllocation epoch nodeId, version) ->
          return (Just (ResourceAllocationValue (epoch, nodeId, version)))
        Nothing -> return Nothing

lookupNodePersistWithCache = lookupResourceAllocationWithCache

lookupResourceAllocationWithCache
  :: M.MetaHandle
  -> GossipContext
  -> LoadBalanceHashRing
  -> Text
  -> Text
  -> Maybe Text
  -> IO A.ServerNode
lookupResourceAllocationWithCache metaHandle gossipContext loadBalanceHashRing
                                  key metaId advertisedListenersKey = do
  let racKey = ResourceAllocationKey (key, metaId, advertisedListenersKey)
  (cacheStatus, v_m) <- getResourceAllocationWithCache metaHandle key metaId advertisedListenersKey
  case v_m of
    Nothing -> case cacheStatus of
      CACHE_DELETED -> do
        atomicModifyIORef' (racMap resourceAllocationCache)
                           (\m -> (Map.delete racKey m, ()))
        lookupResourceAllocationWithCache metaHandle gossipContext loadBalanceHashRing
                                          key metaId advertisedListenersKey
      CACHE_MISS -> do
        (epoch, hashRing) <- readTVarIO loadBalanceHashRing
        theNode <- getResNode hashRing key advertisedListenersKey
        try (M.insertMeta @TaskAllocation
              metaId
              (TaskAllocation epoch (A.serverNodeId theNode))
              metaHandle) >>= \case
          Left (e :: SomeException) -> do
            -- TODO: add a retry limit here
            Log.warning $ "lookupNodePersist exception: " <> Log.buildString' e
                        <> ", retry..."
            lookupResourceAllocationWithCache metaHandle gossipContext loadBalanceHashRing
                                              key metaId advertisedListenersKey
          Right () -> do
            -- update cache and set timeout
            isValid <- newIORef True
            delay   <- newEmptyMVar
            let v = ResourceAllocationValue (epoch, A.serverNodeId theNode, 0)
                item = ResourceAllocationCacheItem v isValid delay
            atomicModifyIORef' (racMap resourceAllocationCache)
                               (\m -> (Map.insert racKey item m, ()))
            Log.info . Log.buildString $ "Oh, new lookup, node=" <> (show (A.serverNodeId theNode))
            void . forkIO $ do
              Log.info . Log.buildString $ "... set timeout for " <> (show (A.serverNodeId theNode))
              threadDelay (resourceAllocationCacheTimeout * 1000)
              atomicModifyIORef' isValid (\_ -> (False, ()))
              putMVar delay ()
            readMVar delay
            return theNode
      _ -> error "impossible..."

    -- allocated & cache is valid, check if the node is still alive
    Just v@(ResourceAllocationValue (epoch_, nodeId_, version_)) -> do
      serverList <- getMemberList gossipContext >>=
        fmap V.concat . mapM (fromInternalServerNodeWithKey advertisedListenersKey)
      case find ((nodeId_ == ) . A.serverNodeId) serverList of
        Just theNode -> do
          case cacheStatus of
            CACHE_VALID -> do
              (ResourceAllocationCacheItem _ _isValid delay) <-
                readIORef (racMap resourceAllocationCache) <&> (\x -> x Map.! racKey)
              readMVar delay
              return theNode
            CACHE_REFRESHED -> do
              (ResourceAllocationCacheItem _ isValid delay) <-
                readIORef (racMap resourceAllocationCache) <&> (\x -> x Map.! racKey)
              atomicModifyIORef' isValid (\_ -> (True, ()))
              void . forkIO $ do
                Log.info . Log.buildString $ "... set timeout for " <> (show nodeId_)
                threadDelay (resourceAllocationCacheTimeout * 1000)
                atomicModifyIORef' isValid (\_ -> (False, ()))
              readMVar delay
              return theNode
            CACHE_MODIFIED -> do
              (ResourceAllocationCacheItem _ isValid delay) <-
                readIORef (racMap resourceAllocationCache) <&> (\x -> x Map.! racKey)
              takeMVar delay
              atomicModifyIORef' isValid (\_ -> (True, ()))
              void . forkIO $ do
                Log.info . Log.buildString $ "... set timeout for " <> (show nodeId_)
                threadDelay (resourceAllocationCacheTimeout * 1000)
                atomicModifyIORef' isValid (\_ -> (False, ()))
                putMVar delay ()
              readMVar delay
              return theNode
            CACHE_MISS -> do
              isValid <- newIORef True
              delay <- newMVar ()
              let item = ResourceAllocationCacheItem v isValid delay
              atomicModifyIORef' (racMap resourceAllocationCache)
                                 (\m -> (Map.insert racKey item m, ()))
              void . forkIO $ do
                Log.info . Log.buildString $ "... set timeout for " <> (show nodeId_)
                threadDelay (resourceAllocationCacheTimeout * 1000)
                atomicModifyIORef' isValid (\_ -> (False, ()))
              readMVar delay
              return theNode
            _ -> error "impossible"
        Nothing -> do
          (epoch', hashRing) <- atomically $ do
            (epoch', hashRing) <- readTVar loadBalanceHashRing
            if epoch' > epoch_
              then pure (epoch', hashRing)
              else retry
          theNode' <- getResNode hashRing key advertisedListenersKey
          try (M.updateMeta @TaskAllocation metaId
                 (TaskAllocation epoch' (A.serverNodeId theNode'))
                 (Just version_) metaHandle) >>= \case
            Left (e :: SomeException) -> do
              -- TODO: add a retry limit here
              Log.warning $ "lookupNodePersist exception: " <> Log.buildString' e
                         <> ", retry..."
              lookupNodePersistWithCache metaHandle gossipContext loadBalanceHashRing
                                         key metaId advertisedListenersKey
            Right () -> do
              ioref <- newIORef True
              mvar  <- newEmptyMVar
              let item = ResourceAllocationCacheItem
                         (ResourceAllocationValue (epoch', A.serverNodeId theNode', version_))
                         ioref mvar
              atomicModifyIORef' (racMap resourceAllocationCache)
                                 (\m -> (Map.insert racKey item m, ()))
              Log.info . Log.buildString $ "Oh, moved, old=" <> (show nodeId_)
                    <> ", new=" <> (show (A.serverNodeId theNode'))
              void . forkIO $ do
                Log.info . Log.buildString $ "... set timeout for " <> (show (A.serverNodeId theNode'))
                threadDelay (resourceAllocationCacheTimeout * 1000)
                atomicModifyIORef' ioref (\_ -> (False, ()))
                putMVar mvar ()
              readMVar mvar
              return theNode'

lookupNode :: LoadBalanceHashRing -> Text -> Maybe Text -> IO A.ServerNode
lookupNode loadBalanceHashRing key advertisedListenersKey = do
  (_, hashRing) <- readTVarIO loadBalanceHashRing
  theNode <- getResNode hashRing key advertisedListenersKey
  return theNode

lookupNodePersist
  :: M.MetaHandle
  -> GossipContext
  -> LoadBalanceHashRing
  -> Text
  -> Text
  -> Maybe Text
  -> IO A.ServerNode
lookupNodePersist metaHandle gossipContext loadBalanceHashRing
                  key metaId advertisedListenersKey = do
  -- FIXME: it will insert the results of lookup no matter the resource exists
  -- or not
  M.getMetaWithVer @TaskAllocation metaId metaHandle >>= \case
    Nothing -> do
      (epoch, hashRing) <- readTVarIO loadBalanceHashRing
      theNode <- getResNode hashRing key advertisedListenersKey
      try (M.insertMeta @TaskAllocation
             metaId
             (TaskAllocation epoch (A.serverNodeId theNode))
             metaHandle) >>= \case
        Left (e :: SomeException) -> do
          -- TODO: add a retry limit here
          Log.warning $ "lookupNodePersist exception: " <> Log.buildString' e
                     <> ", retry..."
          lookupNodePersist metaHandle gossipContext loadBalanceHashRing
                            key metaId advertisedListenersKey
        Right () -> do
          Log.warning $ ">>>>>> Init to " <> Log.buildString' (A.serverNodeId theNode)
          return theNode
    Just (TaskAllocation epoch nodeId, version) -> do
      serverList <- getMemberList gossipContext >>=
        fmap V.concat . mapM (fromInternalServerNodeWithKey advertisedListenersKey)
      case find ((nodeId == ) . A.serverNodeId) serverList of
        Just theNode -> return theNode
        Nothing -> do
          (epoch', hashRing) <- atomically $ do
              (epoch', hashRing) <- readTVar loadBalanceHashRing
              if epoch' > epoch
                then pure (epoch', hashRing)
                else retry
          theNode' <- getResNode hashRing key advertisedListenersKey
          try (M.updateMeta @TaskAllocation metaId
                 (TaskAllocation epoch' (A.serverNodeId theNode'))
                 (Just version) metaHandle) >>= \case
            Left (e :: SomeException) -> do
              -- TODO: add a retry limit here
              Log.warning $ "lookupNodePersist exception: " <> Log.buildString' e
                         <> ", retry..."
              lookupNodePersist metaHandle gossipContext loadBalanceHashRing
                                key metaId advertisedListenersKey
            Right () -> do
              Log.warning $ ">>>>>> lookup got " <> Log.buildString' nodeId <> ", but seems dead. Use " <> Log.buildString' (A.serverNodeId theNode')
              return theNode'

data KafkaResource
  = KafkaResTopic Text
  | KafkaResGroup Text

kafkaResourceKey :: KafkaResource -> Text
kafkaResourceKey (KafkaResTopic name) = name
kafkaResourceKey (KafkaResGroup name) = name

kafkaResourceMetaId :: KafkaResource -> Text
kafkaResourceMetaId (KafkaResTopic name) = "KafkaResTopic_" <> name
kafkaResourceMetaId (KafkaResGroup name) = "KafkaResGroup_" <> name

lookupKafka :: LoadBalanceHashRing -> Maybe Text -> KafkaResource -> IO A.ServerNode
lookupKafka lbhr alk res = lookupNode lbhr (kafkaResourceKey res) alk

lookupKafkaPersist
  :: M.MetaHandle
  -> GossipContext
  -> LoadBalanceHashRing
  -> Maybe Text
  -> KafkaResource
  -> IO A.ServerNode
lookupKafkaPersist mh gc lbhr alk kafkaResource =
  let key = kafkaResourceKey kafkaResource
      metaId = kafkaResourceMetaId kafkaResource
   in lookupNodePersist mh gc lbhr key metaId alk

lookupKafkaPersistWithCache
  :: M.MetaHandle
  -> GossipContext
  -> LoadBalanceHashRing
  -> Maybe Text
  -> KafkaResource
  -> IO A.ServerNode
lookupKafkaPersistWithCache mh gc lbhr alk kafkaResource =
  let key = kafkaResourceKey kafkaResource
      metaId = kafkaResourceMetaId kafkaResource
   in lookupNodePersistWithCache mh gc lbhr key metaId alk
