{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module HStream.Server.Handler.Cluster
  ( describeClusterHandler
  , lookupStreamHandler
  , lookupSubscriptionHandler
  ) where

import           Control.Concurrent
import           Data.Functor
import qualified Data.Map.Strict                  as Map
import qualified Data.Text                        as T
import qualified Data.Vector                      as V
import           Network.GRPC.HighLevel.Generated
import           ZooKeeper.Types

import           HStream.Server.Exception         (defaultExceptionHandle)
import           HStream.Server.HStreamApi
import           HStream.Server.LoadBalance       (getNodesRanking)
import qualified HStream.Server.Persistence       as P
import           HStream.Server.Types
import qualified HStream.Server.Types             as Types
import           HStream.ThirdParty.Protobuf      (Empty)
import           HStream.Utils

--------------------------------------------------------------------------------

describeClusterHandler :: ServerContext
                       -> ServerRequest 'Normal Empty DescribeClusterResponse
                       -> IO (ServerResponse 'Normal DescribeClusterResponse)
describeClusterHandler ctx (ServerNormalRequest _meta _) = defaultExceptionHandle $ do
  let protocolVer = Types.protocolVersion
      serverVer   = Types.serverVersion
  nodes <- getNodesRanking ctx <&> V.fromList
  return $ ServerNormalResponse (Just $ DescribeClusterResponse protocolVer serverVer nodes) mempty StatusOk ""

lookupStreamHandler :: ServerContext
                    -> ServerRequest 'Normal LookupStreamRequest LookupStreamResponse
                    -> IO (ServerResponse 'Normal LookupStreamResponse)
lookupStreamHandler ctx@ServerContext{..} (ServerNormalRequest _meta (LookupStreamRequest stream)) = defaultExceptionHandle $ do
  prdCtxs <- P.listObjects @ZHandle @'P.PrdCtxRep zkHandle
  case Map.lookup stream prdCtxs of
    Nothing -> do
      allNodes <- getNodesRanking ctx
      case allNodes of
        []       -> returnErrResp StatusInternal "No available server node"
        newNode:_ -> do
          let prdCtx = ProducerContext stream newNode
          P.storeObject stream prdCtx zkHandle
          let resp = LookupStreamResponse
                     { lookupStreamResponseStreamName = stream
                     , lookupStreamResponseServerNode = Just newNode
                     }
          returnResp resp
    Just ProducerContext{..} -> do
      let resp = LookupStreamResponse
                 { lookupStreamResponseStreamName = _prdctxStream
                 , lookupStreamResponseServerNode = Just _prdctxNode
                 }
      returnResp resp

lookupSubscriptionHandler :: ServerContext
                          -> ServerRequest 'Normal LookupSubscriptionRequest LookupSubscriptionResponse
                          -> IO (ServerResponse 'Normal LookupSubscriptionResponse)
lookupSubscriptionHandler ctx@ServerContext{..} (ServerNormalRequest _meta (LookupSubscriptionRequest subId)) = defaultExceptionHandle $ do
  subCtxs <- P.listObjects zkHandle
  case Map.lookup subId subCtxs of
    Nothing -> do
      P.checkIfExist @ZHandle @'P.SubRep subId zkHandle >>= \case
        False -> returnErrResp StatusInternal "No subscription found"
        True  -> do
          getNodesRanking ctx >>= \case
            []     -> returnErrResp StatusInternal "No available node for the subscription"
            node:_ -> do
              let subCtx = SubscriptionContext { _subctxNode = serverNodeId node }
              modifyMVar_ subscriptionCtx
                (\ctxs -> do
                    newCtxMVar <- newMVar subCtx
                    return $ Map.insert (T.unpack subId) newCtxMVar ctxs
                )
              P.storeObject subId subCtx zkHandle -- sync subctx to zk
              doResp subId node
    Just SubscriptionContext{..} -> do
      serverNode <- P.getServerNode zkHandle _subctxNode
      doResp subId serverNode
  where
    doResp subscriptionId node = do
      let resp = LookupSubscriptionResponse
                 { lookupSubscriptionResponseSubscriptionId = subscriptionId
                 , lookupSubscriptionResponseServerNode = Just node
                 }
      returnResp resp
