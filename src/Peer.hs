{-# LANGUAGE ScopedTypeVariables #-}
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
import Prelude hiding (pred, succ, catch)
import Control.Exception.Base
import Constants
import System.Directory




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
          leave currentNode predecessorNode successorNode
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

      -- inicializa a pasta na qual os arquivos serao guardados
      createDirectory $ nodeDir <> "/" <> show (hashTestFromDHTNode me)

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



leave :: Me -> MVar PredecessorNode -> MVar SuccessorNode -> IO ()
leave me mPred mSucc = do
  -- pega o antecessor e o sucessor e tranca a variavel
  pred <- takeMVar mPred
  succ <- takeMVar mSucc

  let
    predConfig = makeClientConfig (getHost pred) (getPort pred)
    succConfig = makeClientConfig (getHost succ) (getPort succ)
    leaveMsg = LEAVE
      { leavePredPort=fromIntegral $ unPort $ getPort pred
      , leavePredIp=byteStringToLText $ unHost $ getHost pred
      , leavePredIdTest=fromIntegral $ hashTestFromDHTNode pred
      , leavePredId=fromIntegral $ hashTestFromDHTNode pred
      }
    nodeGoneMsg = NODEGONE
      { nodegoneSuccPort=fromIntegral $ unPort $ getPort succ
      , nodegoneSuccIp=byteStringToLText $ unHost $ getHost succ
      , nodegoneSuccIdTest=fromIntegral $ hashTestFromDHTNode succ
      , nodegoneSuccId=fromIntegral $ hashTestFromDHTNode succ
      }

  putMVar mPred pred -- fazer isso nessa ordem pode dar problema?
  putMVar mSucc succ

  sendLeave succConfig leaveMsg

  sendNodeGone predConfig nodeGoneMsg

  -- TRANSFER

  -- apos mensagem de sucesso de transfer, apagar toda a pasta e arquivos
  removeDirectoryRecursive $ nodeDir <> "/" <> show (hashTestFromDHTNode me)

  where

    sendLeave :: ClientConfig -> LEAVE -> IO ()
    sendLeave config req = withGRPCClient config $ \client -> do
      putStrLn "Sending LEAVE to successor"
      Chord{ chordLeave } <- chordClient client
      fullRes <- chordLeave (ClientNormalRequest req 10 mempty)

      case fullRes of
        (ClientNormalResponse LEAVEOK _meta1 _meta2 _status _details) -> do
          putStrLn "Left successor node succesfully"

        (ClientErrorResponse err) -> do
          print err

    sendNodeGone :: ClientConfig -> NODEGONE -> IO ()
    sendNodeGone config req = withGRPCClient config $ \client -> do
      putStrLn "Sending NODEGONE to predecessor"
      Chord{ chordNodeGone } <- chordClient client
      fullRes <- chordNodeGone (ClientNormalRequest req 10 mempty)

      case fullRes of
        (ClientNormalResponse NODEGONEOK _meta1 _meta2 _status _details) -> do
          putStrLn "Left predecessor node succesfully"

        (ClientErrorResponse err) -> do
          print err