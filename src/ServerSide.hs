{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}

module ServerSide (runServer, sendTransfer) where

import Chord
import DHTTypes
import Utils

import Network.GRPC.HighLevel.Generated
import Control.Concurrent
import Data.Text.Lazy as TL
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics
import qualified Data.ByteString as BS

import Data.Hashable (hash)
import qualified GHC.Word
import Prelude hiding (succ, pred)
import Network.GRPC.LowLevel.Call (endpoint)
import System.Directory
import Constants



runServer :: Host -> Port -> MVar PredecessorNode -> MVar SuccessorNode -> IO ()
runServer myHost myPort mPred mSucc = chordServer
  (handlers (DHTNode myHost myPort) mPred mSucc)
  defaultServiceOptions
    { serverHost = myHost
    , serverPort = myPort
    }



handlers :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  Chord ServerRequest ServerResponse
handlers me mPred mSucc = Chord
  { chordJoin = joinHandler mPred mSucc
  , chordJoinV2 = joinV2Handler me mPred mSucc
  , chordJoinOk = joinOkHandler mPred mSucc
  , chordRoute = routeHandler me mPred mSucc
  , chordNewNode = newNodeHandler mSucc
  , chordLeave = leaveHandler mPred
  , chordNodeGone = nodeGoneHandler mSucc
  , chordStore = storeHandler me mPred mSucc
  , chordRetrieve = retrieveHandler me mPred mSucc
  , chordRetrieveFinished = retrieveFinishedHandler
  , chordTransfer = transferHandler me
  }


joinV2Handler :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  ServerRequest 'Normal JOIN JOINREQUESTED ->
  IO (ServerResponse 'Normal JOINREQUESTED)
joinV2Handler
  me@(DHTNode myHost myPort)
  mPred
  mSucc
  (ServerNormalRequest _meta joinMsg@(JOIN joinId joinIp joinPort joinIdTest)) = do
    putStrLn $ joinV2LogMsg joinIp joinPort -- FIXME: nao loga quem enviou a mensage

    -- acessa o predecessor deste no e faz o lock nessa variavel
    pred@(DHTNode predHost predPort) <- takeMVar mPred

    -- calcula o hash deste no e do predecessor deste no
    -- ATENCAO: estamos usando o hash de teste, que e so um Int comum e varia
    -- de 0 a 7. depois temos que trocar para o hash de verdade
    let
      joinedNode@(DHTNode joinedNodeHost joinedNodePort) = makeDHTNode joinIp joinPort
      myHash = hashTestFromDHTNode me
      predHash = hashTestFromDHTNode pred
      candidateHash = fromIntegral joinIdTest

    -- logs dos hashes
    -- putStrLn $ "myHash: " <> show myHash
    -- putStrLn $ "predHash: " <> show predHash
    -- putStrLn $ "candidateHash: " <> show candidateHash
    -- putStrLn $ "isResponsible: " <> show (isResponsible predHash myHash candidateHash)

    -- se o id do novo nó é responsabilidade deste nó
    _ <- if isResponsible predHash myHash candidateHash
      then do
        -- gera as mensagens que vamos usar nas requisicoes
        let
          newNodeMsg = NEWNODE
            { newnodeSuccPort=joinPort
            , newnodeSuccIp=joinIp
            }

          joinOkMsg = JOINOK
            { joinokSuccPort=fromIntegral $ unPort myPort
            , joinokSuccIp=byteStringToLText $ unHost myHost
            , joinokPredPort=fromIntegral $ unPort predPort
            , joinokPredIp=byteStringToLText $ unHost predHost
            , joinokJoinedIdTest=joinIdTest
            , joinokJoinedId=joinId
            }

        -- manda mensagem para o predecessor deste nó para apontar para o novo
        -- nó que entrou na rede
        _ <- forkIO $ sendNewNode (makeClientConfig (getHost pred) (getPort pred)) newNodeMsg

        -- manda mensagem para o novo nó avisando que ele entrou na rede
        let
          joinedNodeConfig = makeClientConfig joinedNodeHost joinedNodePort
          pathToMyFiles = nodeDir <> "/" <> show myHash

        allMyFiles <- listDirectory pathToMyFiles
        let filesToTransfer = retrieveFilesForTransfer predHash candidateHash allMyFiles
        sendJoinOk joinedNodeConfig joinOkMsg
        _ <- forkIO $ sendTransfer pathToMyFiles filesToTransfer joinedNodeConfig

        -- atualiza o predecessor desse nó
        putMVar mPred joinedNode
        putStrLn $ "JoinV2 pred: " <> show joinedNode

      -- se o id do novo nó não é responsabilidade deste nó
      else do
        -- destrava a variavel do predecessor. nao precisamos dela nesse caso
        putMVar mPred pred

        -- acessa o sucessor deste no e faz o lock na variavel
        succ@(DHTNode succHost succPort) <- takeMVar mSucc

        -- reenvia o pedido de join para o sucessor deste nó
        _ <- forkIO $ sendJoin (makeClientConfig succHost succPort) joinMsg

        -- destrava a variavel do sucessor
        putMVar mSucc succ

    -- responde o nó que enviou o JOIN para este nó
    return $ ServerNormalResponse JOINREQUESTED [] StatusOk ""

      where
        -- constroi mensagem de log para esse handler
        joinV2LogMsg = makeLogMessage "JOINV2" "Request RECEIVED to join network"

        -- funcoes de envio de mensagem
        -- eu forneco o endereco de quem vai receber a mensagem via ClientConfig
        -- e a mensagem que eu quero enviar como segundo argumento
        -- a funcao faz o envio e imprime a resposta

        -- as tres funcoes fazem o mesma coisa. com certeza da pra refatorar
        sendJoin :: ClientConfig -> JOIN -> IO ()
        sendJoin config req = withGRPCClient config $ \client -> do
          putStrLn "Forwarded Join request to successor"
          Chord{ chordJoinV2 } <- chordClient client
          fullRes <- chordJoinV2 (ClientNormalRequest req 10 mempty)

          case fullRes of
            (ClientNormalResponse JOINREQUESTED _meta1 _meta2 _status _details) -> do
              putStrLn "Join request handled successfully"

            (ClientErrorResponse err) -> do
              print err

        sendJoinOk :: ClientConfig -> JOINOK -> IO ()
        sendJoinOk config req = withGRPCClient config $ \client -> do
          putStrLn "Sent welcome request to new node"
          Chord{ chordJoinOk } <- chordClient client
          fullRes <- chordJoinOk (ClientNormalRequest req 10 mempty)

          case fullRes of
            (ClientNormalResponse JOINSUCCESSFUL _meta1 _meta2 _status _details) -> do
              putStrLn "JoinOk request handled successfully"

            (ClientErrorResponse err) -> do
              print err

        sendNewNode :: ClientConfig -> NEWNODE -> IO ()
        sendNewNode config req = withGRPCClient config $ \client -> do
          putStrLn "Sent successor update message to my predecessor"
          Chord{ chordNewNode } <- chordClient client
          fullRes <- chordNewNode (ClientNormalRequest req 10 mempty)

          case fullRes of
            (ClientNormalResponse NEWNODEOK _meta1 _meta2 _status _details) -> do
              putStrLn "NewNode request handled successfully"

            (ClientErrorResponse err) -> do
              print err

joinOkHandler :: MVar PredecessorNode ->
  MVar SuccessorNode ->
  ServerRequest 'Normal JOINOK JOINSUCCESSFUL ->
  IO (ServerResponse 'Normal JOINSUCCESSFUL)
joinOkHandler
  mPred
  mSucc
  (ServerNormalRequest _meta (JOINOK _ joinPredIp joinPredPort joinSuccIp joinSuccPort joinIdTest)) = do
    putStrLn "[JOINOK] --- Accepted in the network. Updating my neighbors."

    -- Converte o IP e a porta do novo nó para o formato apropriado
    let
      newPred = makeDHTNode joinPredIp joinPredPort
      newSucc = makeDHTNode joinSuccIp joinSuccPort

    -- atualiza o antecessor e o sucessor do no atual
    _ <- putMVar mPred newPred
    _ <- putMVar mSucc newSucc

    createDirectoryIfMissing False $ nodeDir <> "/" <> show joinIdTest
    -- putStrLn $ "JoinOk pred: " <> show newPred
    -- putStrLn $ "JoinOk succ: " <> show newSucc

    return $ ServerNormalResponse JOINSUCCESSFUL [] StatusOk ""

-- | DEPRECATED
joinHandler = undefined

-- | DEPRECATED
routeHandler = undefined


newNodeHandler :: MVar SuccessorNode ->
  ServerRequest 'Normal NEWNODE NEWNODEOK ->
  IO (ServerResponse 'Normal NEWNODEOK)
newNodeHandler mSucc (ServerNormalRequest _metadata (NEWNODE newNodeIp newNodePort)) = do
  putStrLn "[NEWNODE] --- Request to update my successor"

  -- Converte o IP e a porta do novo nó para o formato apropriado
  let newNode = makeDHTNode newNodeIp newNodePort
  putStrLn $ "NewNode succ: " <> show newNode

  -- atualiza o sucessor do no atual
  _ <- swapMVar mSucc newNode

  -- Retornar uma resposta de sucesso
  return $ ServerNormalResponse NEWNODEOK [] StatusOk ""



leaveHandler ::
  MVar PredecessorNode ->
  ServerRequest 'Normal LEAVE LEAVEOK ->
  IO (ServerResponse 'Normal LEAVEOK)
leaveHandler mPred (ServerNormalRequest _metadata (LEAVE _ predIp predPort _)) = do
  -- Obtém o predecessor atual
  _ <- takeMVar mPred

  let newNode = makeDHTNode predIp predPort

  -- Atualiza o predecessor com os valores recebidos na requisição de LEAVE
  putMVar mPred newNode

  -- Envia a resposta LEAVEOK
  return $ ServerNormalResponse LEAVEOK [] StatusOk ""



nodeGoneHandler ::
  MVar SuccessorNode ->
  ServerRequest 'Normal NODEGONE NODEGONEOK ->
  IO (ServerResponse 'Normal NODEGONEOK)
nodeGoneHandler mSucc (ServerNormalRequest _metadata (NODEGONE _ succIp succPort _)) = do
  -- Obtém o sucessor atual
  _ <- takeMVar mSucc

  let newNode = makeDHTNode succIp succPort

  -- Atualiza o sucessor com os valores recebidos na requisição de NODEGONE
  putMVar mSucc newNode

  -- Envia a resposta NODEGONEOK
  return $ ServerNormalResponse NODEGONEOK [] StatusOk ""



-- Definições dos handlers não implementados:
storeHandler :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  ServerRequest 'Normal STORE STOREREQUESTED ->
  IO (ServerResponse 'Normal STOREREQUESTED)
storeHandler
  me
  mPred
  mSucc
  (ServerNormalRequest _meta storeMsg@(STORE key _ value keyTest)) = do
    -- acessa o predecessor deste no e faz o lock nessa variavel
    pred <- takeMVar mPred

    -- calcula o hash deste no e do predecessor deste no
    -- ATENCAO: estamos usando o hash de teste, que e so um Int comum e varia
    -- de 0 a 7. depois temos que trocar para o hash de verdade
    let
      myHash = hashTestFromDHTNode me
      predHash = hashTestFromDHTNode pred
      candidateHash = fromIntegral keyTest

    _ <- if isResponsible predHash myHash candidateHash
      then do
        -- guarda o arquivo na pasta data, sob o indice desse no
        BS.writeFile (nodeDir <> "/" <> show myHash <> "/" <> show keyTest) value

        -- destranca predecessor
        putMVar mPred pred
      else do
        -- destrava a variavel do predecessor. nao precisamos dela nesse caso
        putMVar mPred pred

        -- acessa o sucessor deste no e faz o lock na variavel
        succ@(DHTNode succHost succPort) <- takeMVar mSucc

        -- reenvia o pedido de join para o sucessor deste nó
        _ <- forkIO $ sendStore (makeClientConfig succHost succPort) storeMsg

        -- destrava a variavel do sucessor
        putMVar mSucc succ
    return $ ServerNormalResponse STOREREQUESTED [] StatusOk ""

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



retrieveHandler :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  ServerRequest 'Normal RETRIEVE RETRIEVEACK ->
  IO (ServerResponse 'Normal RETRIEVEACK)
retrieveHandler
  me
  mPred
  mSucc
  (ServerNormalRequest
    _meta
    retrieveMsg@(RETRIEVE key _ _ requirerIp requiererPort keyTest)) = do

  -- acessa o predecessor deste no e faz o lock nessa variavel
  pred <- takeMVar mPred

  -- calcula o hash deste no e do predecessor deste no
  -- ATENCAO: estamos usando o hash de teste, que e so um Int comum e varia
  -- de 0 a 7. depois temos que trocar para o hash de verdade
  let
    myHash = hashTestFromDHTNode me
    predHash = hashTestFromDHTNode pred
    candidateHash = fromIntegral keyTest

  _ <- if isResponsible predHash myHash candidateHash
    then do
      -- destrava o predecessor
      putMVar mPred pred

      retrieveFinishedSetup
        (makeClientConfig (textToHost requirerIp) (toPort requiererPort))
    else do
      -- roteia a mensagem
      -- destrava a variavel do predecessor. nao precisamos dela nesse caso
      putMVar mPred pred

      -- acessa o sucessor deste no e faz o lock na variavel
      succ@(DHTNode succHost succPort) <- takeMVar mSucc

      -- reenvia o pedido de join para o sucessor deste nó
      _ <- forkIO $ sendRetrieve (makeClientConfig succHost succPort) retrieveMsg

      -- destrava a variavel do sucessor
      putMVar mSucc succ

  return $ ServerNormalResponse RETRIEVEACK [] StatusOk ""

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

      retrieveFinishedSetup :: ClientConfig -> IO ()
      retrieveFinishedSetup config = do
        let
          fileNameWithPath =
            nodeDir
            <> "/"
            <> show (hashTestFromDHTNode me)
            <> "/"
            <> show keyTest

        fileExists <- doesFileExist fileNameWithPath
        req <- if fileExists
          then do
            fileContent <- BS.readFile fileNameWithPath
            let
              okMsg = OK
                { okValue=fileContent
                , okSize=fromIntegral $ BS.length fileContent
                , okKeyTest=keyTest
                , okKey=key
                }
            return (RETRIEVERESPONSE (Just (RETRIEVERESPONSEResponseOk okMsg)))
          else do
            return (RETRIEVERESPONSE (Just (RETRIEVERESPONSEResponseNotFound NOTFOUND)))
        sendRetrieveFinished config req

      sendRetrieveFinished :: ClientConfig -> RETRIEVERESPONSE -> IO ()
      sendRetrieveFinished config req = withGRPCClient config $ \client -> do
        putStrLn "Sending RETRIEVE_RESPONSE to requierer"
        Chord{ chordRetrieveFinished } <- chordClient client
        fullRes <- chordRetrieveFinished (ClientNormalRequest req 10 mempty)

        case fullRes of
          (ClientNormalResponse RETRIEVEACK _meta1 _meta2 _status _details) -> do
            putStrLn "RETRIEVE_RESPONSE acked by requierer"

          (ClientErrorResponse err) -> do
            print err

retrieveFinishedHandler :: ServerRequest 'Normal RETRIEVERESPONSE RETRIEVEACK ->
  IO (ServerResponse 'Normal RETRIEVEACK)
-- caminho feliz: o arquivo foi encontrado e entregue
retrieveFinishedHandler
  (ServerNormalRequest _metadata (RETRIEVERESPONSE
    (Just (RETRIEVERESPONSEResponseOk (OK key _ value keyTest))))) = do
  putStrLn "Arquivo encontrado! Salvando na pasta downloads..."
  BS.writeFile ("downloads/" <> show keyTest) value
  return $ ServerNormalResponse RETRIEVEACK [] StatusOk ""

-- caminho triste: o arquivo nao esta na rede
retrieveFinishedHandler
  (ServerNormalRequest _metadata (RETRIEVERESPONSE
    (Just (RETRIEVERESPONSEResponseNotFound NOTFOUND)))) = do
  putStrLn "O arquivo requerido não existe na rede"
  return $ ServerNormalResponse RETRIEVEACK [] StatusOk ""

-- Sinceramente nao entendo quando esse caso acontece
-- Adicionando somente para completar o pattern matching
retrieveFinishedHandler
  (ServerNormalRequest _metadata (RETRIEVERESPONSE Nothing)) = do
  putStrLn "RETRIEVE_RESPONSE sem conteúdo :("
  return $ ServerNormalResponse RETRIEVEACK [] StatusDataLoss ""



sendTransfer :: FilePath -> [FileName] -> ClientConfig -> IO ()
sendTransfer filePath fileNames config = withGRPCClient config $ \client -> do
  let appendPath fileName = filePath <> "/" <> fileName
  Chord{ chordTransfer } <- chordClient client
  ClientWriterResponse reply _ _ _ _ <- chordTransfer
    $ ClientWriterRequest 10 [] $ \send -> do
      mapM_
        (\fileName -> do
          fileContent <- BS.readFile (appendPath fileName)
          let
            transferReq = TRANSFER
              { transferValue=fileContent
              , transferKeyTest=fromIntegral $ hashTestFile fileName
              , transferKey=fromIntegral $ hashTestFile fileName
              }
          send transferReq)
        fileNames
  putStrLn $ case reply of
    Just _ -> "Arquivos transferidos com sucesso"
    Nothing -> "O Stream falhou"

  -- remove arquivos que foram transferidos
  mapM_
    (\fileName -> removeFile (appendPath fileName))
    fileNames



transferHandler :: Me -> ServerRequest 'ClientStreaming TRANSFER TRANSFEROK ->
  IO (ServerResponse 'ClientStreaming TRANSFEROK)
transferHandler me transferStream@(ServerReaderRequest _metadata recv) = do
  msg <- recv
  case msg of
    -- caso do erro
    (Left err) -> do
      print err
      return
        $ ServerReaderResponse Nothing [] StatusDataLoss "erro no TRANSFER"

    -- caso chegou mensagem
    (Right (Just (TRANSFER key value keyTest))) -> do
      -- guardar arquivo na minha pasta
      BS.writeFile
        (nodeDir <> "/" <> show (hashTestFromDHTNode me) <> "/" <> show keyTest)
        value
      transferHandler me transferStream

    -- caso stream acabou
    (Right Nothing) -> do
      putStrLn "[TRANSFER] --- Fim do stream"
      return
        $ ServerReaderResponse (Just TRANSFEROK) [] StatusOk "Stream encerrado com sucesso"