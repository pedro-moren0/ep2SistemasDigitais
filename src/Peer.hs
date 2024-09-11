{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GADTs #-}
module Peer (module Peer) where

import Chord
import ServerSide (runServer)

import Control.Concurrent (forkIO, MVar, newEmptyMVar)
import Network.GRPC.HighLevel
import Network.GRPC.HighLevel.Generated
import Network.GRPC.LowLevel.Call
import Data.Text.Encoding
import Data.ByteString.Char8 as BSC8 hiding (getLine, putStrLn)
import Data.Text.Lazy as TL
import Data.Bits

data DHTNode = DHTNode Host Port
type PredecessorNode = DHTNode
type SuccessorNode = DHTNode

menuOptionList :: String
menuOptionList =
  "=============================\n\
  \1 - JOIN\n\
  \x - QUIT\n\
  \=============================\n\
  \"

tui :: Port -> IO ()
tui portNumber = do
  (predecesorNode :: MVar DHTNode) <- newEmptyMVar
  (successorNode :: MVar DHTNode) <- newEmptyMVar
  _ <- forkIO $ runServer (Host $ BSC8.pack "localhost") portNumber
  loop predecesorNode successorNode
    where
      loop :: MVar PredecessorNode -> MVar SuccessorNode -> IO ()
      loop predecessorNode successorNode = do
        putStrLn menuOptionList
        s <- getLine
        case s of
          "1" -> do
            otherPort <- getLine
            let iOtherPort = read otherPort :: Int
            join predecessorNode successorNode (DHTNode (Host $ BSC8.pack "localhost") (Port iOtherPort))
            loop predecessorNode successorNode
          "x" -> return ()
          _ -> do
            putStrLn "opcao invalida"
            loop predecessorNode successorNode


-- TODO: Remover o terceiro parametro DHTNode
join :: MVar PredecessorNode -> MVar SuccessorNode -> DHTNode -> IO ()
join mPred mSucc (DHTNode host port) = withGRPCClient clientConfig $ \client -> do
  let requestMessage = JOIN { joinJoinedId = 0, -- TODO: Implementar hashing do ip e porta
    joinJoinedIp = (TL.fromStrict . decodeUtf8 . unHost) host,
    joinJoinedPort = bit $ unPort port,
    joinJoinedIdTest = 0
    }
  
  Chord{ chordJoin } <- chordClient client
  fullRes <- chordJoin (ClientNormalRequest requestMessage 10 [("k", "v")])
  case fullRes of
    (ClientNormalResponse _res _meta1 _meta2 _status _details) -> do
      print ""
    (ClientErrorResponse err) -> do
      print err
  return ()
  where
    clientConfig =
      ClientConfig
        { clientServerEndpoint = endpoint host port
        , clientArgs = []
        , clientSSLConfig = Nothing
        , clientAuthority = Nothing
        }
