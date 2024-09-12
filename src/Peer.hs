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

import Data.Hashable (hash)




menuOptionList :: String
menuOptionList =
  "=============================\n\
  \1 - JOIN\n\
  \2 - LEAVE\n\
  \3 - CHECK ID\n\
  \4 - CHECK NEIGHBORHOOD NODES'S IDS \n\
  \5 - STORE\n\
  \6 - RETRIEVE\n\
  \x - QUIT\n\
  \=============================\n\
  \"

hashTest :: Int -> Int32
hashTest = fromIntegral

tui :: Port -> IO ()
tui portNumber = do
  (predecessorNode :: MVar PredecessorNode) <- newEmptyMVar
  (successorNode :: MVar SuccessorNode) <- newEmptyMVar
  let currentNode = DHTNode (Host $ BSC8.pack "localhost") portNumber -- Inicializa o nó atual
  _ <- forkIO $ runServer (Host $ BSC8.pack "localhost") portNumber predecessorNode successorNode
  loop predecessorNode successorNode currentNode
  where
    loop :: MVar PredecessorNode -> MVar SuccessorNode -> DHTNode -> IO ()
    loop predecessorNode successorNode currentNode = do
      putStrLn menuOptionList
      s <- getLine
      case s of
        "1" -> do
          putStrLn "Digite o número da porta:"
          otherPort <- getLine
          let iOtherPort = read otherPort :: Int
          join predecessorNode successorNode (DHTNode (Host $ BSC8.pack "localhost") (Port iOtherPort))
          loop predecessorNode successorNode currentNode
        "2" -> do
          leave successorNode
          loop predecessorNode successorNode currentNode
        "3" -> do
          let nodeId = calculateNodeId (getHost currentNode) (getPort currentNode)
          putStrLn $ "Meu ID é: " ++ show nodeId
          loop predecessorNode successorNode currentNode
        "4" -> do
          -- Exibir o ID do predecessor, se existir
          maybePredecessor <- tryReadMVar predecessorNode
          case maybePredecessor of
            Just predNode -> putStrLn $ "ID do predecessor: " ++ show (calculateNodeId (getHost predNode) (getPort predNode))
            Nothing -> putStrLn "Predecessor não definido."
          
          -- Exibir o ID do sucessor, se existir
          maybeSuccessor <- tryReadMVar successorNode
          case maybeSuccessor of
            Just succNode -> putStrLn $ "ID do sucessor: " ++ show (calculateNodeId (getHost succNode) (getPort succNode))
            Nothing -> putStrLn "Sucessor não definido."

          loop predecessorNode successorNode currentNode
        "x" -> return ()
        _ -> do
          putStrLn "Opção inválida"
          loop predecessorNode successorNode currentNode

            
calculateNodeId :: Host -> Port -> Int
calculateNodeId (Host ip) (Port port) = (abs (hash (BSC8.unpack ip, port)) `mod` 20) + 1

getHost :: DHTNode -> Host
getHost (DHTNode host _) = host

getPort :: DHTNode -> Port
getPort (DHTNode _ port) = port

textToHost :: Text -> Host
textToHost = textToHost

join :: MVar PredecessorNode -> MVar SuccessorNode -> DHTNode -> IO ()
join mPred mSucc node@(DHTNode (Host host) (Port port)) = withGRPCClient clientConfig $ \client -> do
  let nodeId = calculateNodeId (Host host) (Port port)
      requestMessage = JOIN
        { joinJoinedId = fromIntegral nodeId
        , joinJoinedIp = TL.fromStrict $ decodeUtf8 host
        , joinJoinedPort = fromIntegral port
        , joinJoinedIdTest = fromIntegral nodeId
        }
  
  Chord{ chordJoin } <- chordClient client
  fullRes <- chordJoin (ClientNormalRequest requestMessage 10 mempty)
  
  case fullRes of
    (ClientNormalResponse response _meta1 _meta2 _status _details) -> do
      let newPred = DHTNode (textToHost $ joinokPredIp response) (Port $ fromIntegral $ joinokPredPort response)
          newSucc = DHTNode (textToHost $ joinokSuccIp response) (Port $ fromIntegral $ joinokSuccPort response)
      
      swapMVar mPred newPred
      swapMVar mSucc newSucc
      putStrLn "Join request handled successfully. Predecessor and Successor updated."

    (ClientErrorResponse err) -> do
      print err
  return ()
  where
    clientConfig =
      ClientConfig
        { clientServerEndpoint = endpoint (Host host) (Port $ fromIntegral port)
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
        { clientServerEndpoint = endpoint (Host host) (Port $ fromIntegral port)
        , clientArgs = []
        , clientSSLConfig = Nothing
        , clientAuthority = Nothing
        }

