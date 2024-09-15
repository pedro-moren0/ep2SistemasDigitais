-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}

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
import Text.Read (readMaybe)
import Utils
import Prelude hiding (catch)
import Control.Exception.Base




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
  -- inicializa os mVars do predecessor e do sucessor
  (predecessorNode :: MVar PredecessorNode) <- newEmptyMVar
  (successorNode :: MVar SuccessorNode) <- newEmptyMVar
  let currentNode = DHTNode (Host $ BSC8.pack "localhost") portNumber -- Inicializa o nó atual

  -- escutando requisicoes no background...
  _ <- forkIO $ runServer (Host $ BSC8.pack "localhost") portNumber predecessorNode successorNode

  -- inicializa o "REPL" da aplicacao
  loop predecessorNode successorNode currentNode

  where
    loop :: MVar PredecessorNode -> MVar SuccessorNode -> Me -> IO ()
    loop predecessorNode successorNode currentNode = do
      putStrLn menuOptionList
      s <- getLine
      case s of
        "1" -> do
          interactiveNodeConexion currentNode predecessorNode successorNode
          loop predecessorNode successorNode currentNode
        "2" -> do
          leave successorNode
          loop predecessorNode successorNode currentNode
        "3" -> do
          let nodeId = hashTestFromDHTNode currentNode
          putStrLn $ "Meu ID é: " ++ show nodeId
          loop predecessorNode successorNode currentNode
        "4" -> do
          -- Exibir o ID do predecessor, se existir
          maybePredecessor <- tryReadMVar predecessorNode
          case maybePredecessor of
            Just predNode@(DHTNode _ (Port port)) ->
              putStrLn $ "ID do predecessor: " ++ show (hashTestFromDHTNode predNode) <> ", porta: " <> show port
            Nothing -> putStrLn "Predecessor não definido."

          -- Exibir o ID do sucessor, se existir
          maybeSuccessor <- tryReadMVar successorNode
          case maybeSuccessor of
            Just succNode@(DHTNode _ (Port port)) ->
              putStrLn $ "ID do sucessor: " ++ show (hashTestFromDHTNode succNode) <> ", porta: " <> show port
            Nothing -> putStrLn "Sucessor não definido."

          loop predecessorNode successorNode currentNode
        "x" -> return ()
        _ -> do
          putStrLn "Opção inválida"
          loop predecessorNode successorNode currentNode

interactiveNodeConexion :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  IO ()
interactiveNodeConexion me mPred mSucc = do
  putStrLn
    "Digite o IP do nó a que se deseja conectar, ou x para iniciar uma nova rede: "
  connectionOption <- getLine -- IP que eu quero mandar mensagem

  case connectionOption of
    -- inicializa nova rede
    "x" -> do
      putMVar mPred me
      putMVar mSucc me

    -- tenta conexao com um no
    _ -> do
      putStrLn "Digite a porta da conexão: "
      connectionPort <- getLine -- porta do IP que eu quero me conectar

      case (readMaybe connectionPort :: Maybe Int) of
        Just portNumber -> do
          let
            config = makeClientConfig (textToHost $ TL.pack connectionOption) (Port portNumber)

          response <- join config me
          case response of
            ClientNormalResponse _ _ _ _ _ -> do
              putStrLn "Bem vindo à rede! :)"
            ClientErrorResponse err -> do
              print err
              putStrLn "Não foi possível se conectar com o nó fornecido. Tentando novamente..."
              interactiveNodeConexion me mPred mSucc
        Nothing -> do
          putStrLn "Não foi possivel ler o numero da porta"
          interactiveNodeConexion me mPred mSucc


calculateNodeId :: Host -> Port -> Int
calculateNodeId (Host ip) (Port port) = (abs (hash (BSC8.unpack ip, port)) `mod` 20) + 1

getHost :: DHTNode -> Host
getHost (DHTNode host _) = host

getPort :: DHTNode -> Port
getPort (DHTNode _ port) = port

join :: ClientConfig -> DHTNode -> IO (ClientResult 'Normal JOINREQUESTED)
join config (DHTNode h@(Host host) p@(Port port)) = withGRPCClient config $ \client -> do
  let nodeId = hashTestFromDHTNode $ DHTNode h p
      requestMessage = JOIN
        { joinJoinedId = fromIntegral nodeId
        , joinJoinedIp = TL.fromStrict $ decodeUtf8 host
        , joinJoinedPort = fromIntegral port
        , joinJoinedIdTest = fromIntegral nodeId
        }
  putStrLn $ "Calculei meu hash = " <> show nodeId

  Chord{ chordJoinV2 } <- chordClient client
  fullRes <- chordJoinV2 (ClientNormalRequest requestMessage 10 mempty)

  case fullRes of
    (ClientNormalResponse _response _meta1 _meta2 _status _details) -> do
      putStrLn "Join request handled successfully"

    (ClientErrorResponse err) -> do
      print err
  return fullRes



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