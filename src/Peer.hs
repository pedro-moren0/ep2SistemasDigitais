{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Peer (module Peer) where

import Chord
import DHTTypes
import ServerSide (runServer, sendTransfer)
import Constants

import Control.Concurrent
import Network.GRPC.HighLevel.Generated
import Data.Text.Encoding
import qualified Data.ByteString as BS
import Data.Text.Lazy as TL

import Text.Read (readMaybe)
import Utils
import Prelude hiding (pred, succ)
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
  \d - CHECK FILE HASH\n\
  \x - QUIT\n\
  \=============================\n\
  \"

tui :: Host -> Port -> IO ()
tui host port = do
  -- inicializa os mVars do predecessor e do sucessor
  (mPred :: MVar PredecessorNode) <- newEmptyMVar
  (mSucc :: MVar SuccessorNode) <- newEmptyMVar
  let me = DHTNode host port -- Inicializa o nó atual

  -- escutando requisicoes no background...
  _ <- forkIO $ runServer host port mPred mSucc

  -- inicializa o "REPL" da aplicacao
  loop me mPred mSucc

  where
    loop :: Me -> MVar PredecessorNode -> MVar SuccessorNode -> IO ()
    loop me mPred mSucc = do
      putStrLn menuOptionList
      s <- getLine
      case s of
        "1" -> do
          interactiveNodeConexion me mPred mSucc
          loop me mPred mSucc
        "2" -> do
          leave me mPred mSucc
        "3" -> do
          let nodeId = hashTestFromDHTNode me
          putStrLn $ "Meu ID é: " <> show (hashNodeID (unHost $ getHost me) (unPort $ getPort me))
          putStrLn $ "Meu ID (teste) é: " ++ show nodeId
          loop me mPred mSucc
        "4" -> do
          putStrLn "Predecessor:"
          printNode mPred

          putStrLn "Sucessor:"
          printNode mPred

          loop me mPred mSucc
        "5" -> do
          putStrLn "Digite o nome do arquivo (com extensão):"
          fileName <- getLine
          putStrLn "Digite o caminho para o nome do arquivo (com '/' no final):"
          filePath <- getLine
          store mSucc fileName filePath
          loop me mPred mSucc
        "6" -> do
          putStrLn "Digite o nome do arquivo (com extensão):"
          fileName <- getLine
          retrieve me mSucc fileName
          loop me mPred mSucc
        "x" -> return ()
        "d" -> do
          putStrLn "Digite o nome do arquivo (com extensão):"
          fileName <- getLine
          putStrLn $ "ID do arquivo: " <> show (hashFileID fileName)
          putStrLn $ "ID do arquivo (teste): " <> show (hashTestFile fileName)
          loop me mPred mSucc
        _ -> do
          putStrLn "Opção inválida"
          loop me mPred mSucc



printNode :: MVar DHTNode -> IO ()
printNode mNode = do
  maybePredecessor <- tryReadMVar mNode
  case maybePredecessor of
    Just node@(DHTNode (Host host) (Port port)) ->
      putStrLn
        $ "ID: "
        <> show (hashTestFromDHTNode node)
        <> ", host: "
        <> show host
        <> ", porta: "
        <> show port
    Nothing -> putStrLn "Nó não definido."


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
      createDirectoryIfMissing False $ nodeDir <> show (hashTestFromDHTNode me)

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
            ClientNormalResponse {} -> do
              putStrLn "Bem vindo à rede! :)"
            ClientErrorResponse err -> do
              print err
              putStrLn "Não foi possível se conectar com o nó fornecido. Tentando novamente..."
              interactiveNodeConexion me mPred mSucc
        Nothing -> do
          putStrLn "Não foi possivel ler o numero da porta"
          interactiveNodeConexion me mPred mSucc



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
    myHash = hashTestFromDHTNode me
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
  let pathToMyFiles = nodeDir <> show myHash
  allMyFiles <- listDirectory pathToMyFiles
  sendTransfer (nodeDir <> show (hashTestFromDHTNode me)) allMyFiles succConfig

  -- apos mensagem de sucesso de transfer, apagar toda a pasta e arquivos
  removeDirectoryRecursive $ nodeDir <> show (hashTestFromDHTNode me)

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



store :: MVar SuccessorNode -> FileName -> FilePath -> IO ()
store mSucc fileName filePath = do
  succ <- takeMVar mSucc -- TODO: trocar para readMVar
  fileContent <- BS.readFile $ filePath <> fileName

  let
    key = hashTestFile fileName
    config = makeClientConfig (getHost succ) (getPort succ)
    reqMsg = STORE
      { storeValue=fileContent
      , storeSize=fromIntegral $ BS.length fileContent
      , storeKeyTest=fromIntegral key
      , storeKey=fromIntegral key
      }
  putMVar mSucc succ
  sendStore config reqMsg
  where
    sendStore :: ClientConfig -> STORE -> IO ()
    sendStore config req = withGRPCClient config $ \client -> do
      putStrLn "Sending STORE to successor"
      Chord{ chordStore } <- chordClient client
      fullRes <- chordStore (ClientNormalRequest req 10 mempty)

      case fullRes of
        (ClientNormalResponse STOREREQUESTED _meta1 _meta2 _status _details) -> do
          putStrLn "STORE request received by successor"

        (ClientErrorResponse err) -> do
          print err



retrieve :: Me -> MVar SuccessorNode -> FileName -> IO ()
retrieve me mSucc fileName = do
  succ <- readMVar mSucc

  let
    retrieveMsg = RETRIEVE
      { retrieveRequirerPort=fromIntegral $ unPort $ getPort me
      , retrieveRequirerIp=byteStringToLText $ unHost $ getHost me
      , retrieveRequirerIdTes=fromIntegral $ hashTestFromDHTNode me
      , retrieveRequirerId=fromIntegral $ hashTestFromDHTNode me
      , retrieveKeyTest=fromIntegral $ hashTestFile fileName
      , retrieveKey=fromIntegral $ hashTestFile fileName
      }
    config = makeClientConfig (getHost succ) (getPort succ)

  sendRetrieve config retrieveMsg
  where
    sendRetrieve :: ClientConfig -> RETRIEVE -> IO ()
    sendRetrieve config req = withGRPCClient config $ \client -> do
      putStrLn "Sending RETRIEVE to successor"
      Chord{ chordRetrieve } <- chordClient client
      fullRes <- chordRetrieve (ClientNormalRequest req 10 mempty)

      case fullRes of
        (ClientNormalResponse RETRIEVEACK _meta1 _meta2 _status _details) -> do
          putStrLn "RETRIEVE request received by a node"

        (ClientErrorResponse err) -> do
          print err