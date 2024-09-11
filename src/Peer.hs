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
import Control.Concurrent.MVar
import Data.Int (Int32)
import Control.Exception

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
  (predecessorNode :: MVar PredecessorNode) <- newEmptyMVar
  (successorNode :: MVar SuccessorNode) <- newEmptyMVar
  _ <- forkIO $ runServer (Host $ BSC8.pack "localhost") portNumber predecessorNode successorNode
  loop predecessorNode successorNode
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
          "2" -> do
            leave successorNode
            loop predecessorNode successorNode
          "x" -> return ()
          _ -> do
            putStrLn "Opção inválida"
            loop predecessorNode successorNode

join :: MVar PredecessorNode -> MVar SuccessorNode -> DHTNode -> IO ()
join mPred mSucc (DHTNode (Host host) (Port port)) = withGRPCClient clientConfig $ \client -> do
  let requestMessage = JOIN
        { joinJoinedId = 0  -- Substitua com um ID adequado
        , joinJoinedIp = TL.fromStrict $ decodeUtf8 host
        , joinJoinedPort = fromIntegral port
        , joinJoinedIdTest = hashTest port
        }
  
  Chord{ chordJoin } <- chordClient client
  fullRes <- chordJoin (ClientNormalRequest requestMessage 10 mempty)
  case fullRes of
    (ClientNormalResponse _res _meta1 _meta2 _status _details) -> do
      putStrLn "Join request sent successfully."
    (ClientErrorResponse err) -> do
      print err
  return ()
  where
    clientConfig =
      ClientConfig
        { clientServerEndpoint = endpoint (Host $ host) (Port $ fromIntegral port)
        , clientArgs = []
        , clientSSLConfig = Nothing
        , clientAuthority = Nothing
        }

leave :: MVar SuccessorNode -> IO ()
leave mSucc = do
  -- Obtém o successor atual
  DHTNode (Host hostBS) (Port port) <- readMVar mSucc
  
  -- Converte o IP para Text e cria a mensagem LEAVE
  let succIp = TL.fromStrict $ decodeUtf8 hostBS
  let requestMessage = LEAVE
        { leavePredId = 0  -- Substitua com um ID adequado
        , leavePredIp = succIp
        , leavePredPort = fromIntegral port
        , leavePredIdTest = 0  -- Substitua com um ID adequado
        }
  
  -- Cria o cliente gRPC e envia a solicitação
  result <- try $ withGRPCClient (clientConfig hostBS port) $ \client -> do
    Chord { chordLeave } <- chordClient client
    chordLeave (ClientNormalRequest requestMessage 10 mempty)
  
  -- Processa a resposta
  case result of
    Left err -> putStrLn $ "Erro ao enviar request LEAVE: " ++ show (err :: SomeException)
    Right (ClientNormalResponse _res _meta1 _meta2 _status _details) -> putStrLn "Leave request sent successfully."
    Right (ClientErrorResponse err) -> putStrLn $ "Erro na resposta LEAVE: " ++ show err
  where
    -- Configuração do cliente gRPC
    clientConfig host port =
      ClientConfig
        { clientServerEndpoint = endpoint (Host $ host) (Port $ fromIntegral port)
        , clientArgs = []
        , clientSSLConfig = Nothing
        , clientAuthority = Nothing
        }

