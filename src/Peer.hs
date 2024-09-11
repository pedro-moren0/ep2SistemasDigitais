{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GADTs #-}
module Peer (module Peer) where

import Chord
import DHTTypes
import ServerSide (runServer)

import Control.Concurrent (forkIO, MVar, newEmptyMVar)
import Network.GRPC.HighLevel
import Network.GRPC.HighLevel.Generated
import Network.GRPC.LowLevel.Call
import Data.Text.Encoding
import Data.ByteString.Char8 as BSC8 hiding (getLine, putStrLn)
import Data.Text.Lazy as TL
import Data.Bits
import Data.Int (Int32)

menuOptionList :: String
menuOptionList =
  "=============================\n\
  \1 - JOIN\n\
  \2 - LEAVE\n\
  \3 - STORE\n\
  \4 - RETRIEVE\n\
  \x - QUIT\n\
  \=============================\n\
  \"

hashTest :: Int -> Int32
hashTest = fromIntegral

tui :: Port -> IO ()
tui portNumber = do
  (predecesorNode :: MVar PredecessorNode) <- newEmptyMVar
  (successorNode :: MVar SuccessorNode) <- newEmptyMVar
  _ <- forkIO $ runServer (Host $ BSC8.pack "localhost") portNumber predecesorNode successorNode
  loop predecesorNode successorNode
    where
      loop :: MVar PredecessorNode -> MVar SuccessorNode -> IO ()
      loop predecessorNode successorNode = do
        putStrLn menuOptionList
        s <- getLine
        case s of
          "1" -> do
            -- TESTE --
            otherPort <- getLine
            let iOtherPort = read otherPort :: Int
            -- TESTE --
            join predecessorNode successorNode (DHTNode (Host $ BSC8.pack "localhost") (Port iOtherPort))
            loop predecessorNode successorNode
          "2" -> do
            leave successorNode
            loop predecessorNode successorNode
          "x" -> return ()
          _ -> do
            putStrLn "opcao invalida"
            loop predecessorNode successorNode


-- TODO: Remover o terceiro parametro DHTNode
join :: MVar PredecessorNode -> MVar SuccessorNode -> DHTNode -> IO ()
join mPred mSucc (DHTNode hostADT@(Host host) portADT@(Port port)) = withGRPCClient clientConfig $ \client -> do
  let requestMessage = JOIN { joinJoinedId = 0, -- TODO: Implementar hashing do ip e porta
    joinJoinedIp = (TL.fromStrict . decodeUtf8) host,
    joinJoinedPort = bit port,
    joinJoinedIdTest = hashTest port
    }

  Chord{ chordJoin } <- chordClient client
  fullRes <- chordJoin (ClientNormalRequest requestMessage 10 mempty)
  case fullRes of
    (ClientNormalResponse _res _meta1 _meta2 _status _details) -> do
      print ""
    (ClientErrorResponse err) -> do
      print err
  return ()
  where
    clientConfig =
      ClientConfig
        { clientServerEndpoint = endpoint hostADT portADT
        , clientArgs = []
        , clientSSLConfig = Nothing
        , clientAuthority = Nothing
        }
