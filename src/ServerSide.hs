{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}

module ServerSide (runServer) where

import Chord
import DHTTypes
import Utils

import Network.GRPC.HighLevel.Generated
import Control.Concurrent
import Data.Text.Lazy as TL
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics
import Data.ByteString

import Data.Hashable (hash)
import qualified GHC.Word
import Prelude hiding (succ, pred)
import Network.GRPC.LowLevel.Call (endpoint)






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
  , chordStore = storeHandler
  , chordRetrieve = retrieveHandler
  , chordTransfer = transferHandler
  }

calculateNodeId :: Host -> Port -> Int
calculateNodeId (Host ip) (Port port) = hash (ip, port)

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
      newNode@(DHTNode newNodeHost newNodePort) = makeDHTNode joinIp joinPort
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
        _ <- forkIO $ sendJoinOk (makeClientConfig newNodeHost newNodePort) joinOkMsg

        -- atualiza o predecessor desse nó
        putMVar mPred newNode
        putStrLn $ "JoinV2 pred: " <> show newNode

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
  (ServerNormalRequest _meta (JOINOK _ joinPredIp joinPredPort joinSuccIp joinSuccPort _)) = do
    putStrLn "[JOINOK] --- Accepted in the network. Updating my neighbors."

    -- Converte o IP e a porta do novo nó para o formato apropriado
    let
      newPred = makeDHTNode joinPredIp joinPredPort
      newSucc = makeDHTNode joinSuccIp joinSuccPort

    -- atualiza o antecessor e o sucessor do no atual
    _ <- putMVar mPred newPred
    _ <- putMVar mSucc newSucc

    putStrLn $ "JoinOk pred: " <> show newPred
    putStrLn $ "JoinOk succ: " <> show newSucc

    return $ ServerNormalResponse JOINSUCCESSFUL [] StatusOk ""

-- | DEPRECATED
-- joinHandler: função que trata a requisição de JOIN
joinHandler = undefined
-- joinHandler :: MVar PredecessorNode ->
--   MVar SuccessorNode ->
--   ServerRequest 'Normal JOIN JOINOK ->
--   IO (ServerResponse 'Normal JOINOK)
-- joinHandler
--   mPred
--   mSucc
--   (ServerNormalRequest _metadata (JOIN _ joinIp joinPort _)) = do

--   let newNode = DHTNode (textToHost joinIp) (toPort joinPort)
--       nodeId = calculateNodeId (textToHost joinIp) (toPort joinPort)

--   putStrLn $ "Novo nó tentando se juntar: " ++ show newNode

--   currentSucc <- tryReadMVar mSucc
--   currentPred <- tryReadMVar mPred

--   case (currentSucc, currentPred) of
--     (Nothing, Nothing) -> do
--       -- Primeiro nó na rede, ele mesmo é seu sucessor e predecessor
--       putMVar mSucc newNode
--       putMVar mPred newNode
--       putStrLn "Novo nó é o único nó no anel, sucessor e predecessor apontam para ele mesmo."

--       let response = JOINOK
--             { joinokJoinedId = fromIntegral nodeId
--             , joinokPredIp = joinIp
--             , joinokPredPort = fromIntegral joinPort
--             , joinokSuccIp = joinIp
--             , joinokSuccPort = fromIntegral joinPort
--             , joinokJoinedIdTest = fromIntegral nodeId
--             }
--       return $ ServerNormalResponse response [] StatusOk "join com sucesso"

--     (Just succNode, Just predNode) -> do
--       -- Ajustar o predecessor e sucessor para incluir o novo nó
--       putMVar mSucc newNode
--       notifyNewNode predNode newNode

--       let response = JOINOK
--             { joinokJoinedId = fromIntegral nodeId
--             , joinokPredIp = hostToText $ getHost predNode
--             , joinokPredPort = portToInt $ getPort predNode
--             , joinokSuccIp = hostToText $ getHost succNode
--             , joinokSuccPort = portToInt $ getPort succNode
--             , joinokJoinedIdTest = fromIntegral nodeId
--             }

--       return $ ServerNormalResponse response [] StatusOk "join com sucesso"

--   where
--     notifyNewNode :: DHTNode -> DHTNode -> IO ()
--     notifyNewNode predNode newNode = do
--       let newNodeIp = hostToText $ getHost newNode
--           newNodePort = portToInt $ getHost newNode
--       sendNewNodeNotification predNode newNodeIp newNodePort

-- sendNewNodeNotification :: DHTNode -> Text -> GHC.Word.Word32 -> IO ()
-- sendNewNodeNotification = sendNewNodeNotification

-- portToInt :: a2 -> GHC.Word.Word32
-- portToInt = portToInt

-- hostToText :: a5 -> Text
-- hostToText = hostToText




routeHandler :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  ServerRequest 'Normal ROUTE ROUTEOK ->
  IO (ServerResponse 'Normal ROUTEOK)
routeHandler
  me
  mPred
  mSucc
  (ServerNormalRequest _metadata (ROUTE requestData)) = do
  -- Lógica para encaminhar a solicitação para o nó apropriado
  -- Esta é uma parte crítica e pode depender de como você implementa o roteamento
  -- Pode envolver comunicação com o sucessor ou predecessor, dependendo da solicitação

  -- Exemplo básico (necessita ser adaptado conforme o protocolo Chord implementado)
  putStrLn "Routing request..."

  -- Retornar uma resposta de sucesso
  let response = ROUTEOK -- Assumindo que ROUTEOK é o tipo de resposta esperado
  return $ ServerNormalResponse response [] StatusOk ""



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
  currentPred <- takeMVar mPred

  -- Converte o IP de Text para ByteString
  let predIpBS = encodeUtf8 $ TL.toStrict predIp

  -- Atualiza o predecessor com os valores recebidos na requisição de LEAVE
  putMVar mPred (DHTNode (Host predIpBS) (Port $ fromIntegral predPort))

  -- Cria a resposta LEAVEOK para enviar de volta
  let response = LEAVEOK

  -- Envia a resposta LEAVEOK
  return $ ServerNormalResponse response [] StatusOk ""



nodeGoneHandler ::
  MVar SuccessorNode ->
  ServerRequest 'Normal NODEGONE NODEGONEOK ->
  IO (ServerResponse 'Normal NODEGONEOK)
nodeGoneHandler mSucc (ServerNormalRequest _metadata (NODEGONE _ succIp succPort _)) = do
  -- Obtém o sucessor atual
  currentSucc <- takeMVar mSucc

  -- Converte o IP de Text para ByteString
  let succIpBS = encodeUtf8 $ TL.toStrict succIp

  -- Atualiza o sucessor com os valores recebidos na requisição de NODEGONE
  putMVar mSucc (DHTNode (Host succIpBS) (Port $ fromIntegral succPort))

  -- Cria a resposta NODEGONEOK para enviar de volta
  let response = NODEGONEOK -- Se NODEGONEOK não possui campos adicionais, pode ser usado diretamente.

  -- Envia a resposta NODEGONEOK
  return $ ServerNormalResponse response [] StatusOk ""



-- Definições dos handlers não implementados:
storeHandler :: ServerRequest 'Normal STORE STOREOK -> IO (ServerResponse 'Normal STOREOK)
storeHandler _ = do
  -- Implementar o comportamento desejado ou lançar uma exceção
  error "storeHandler não implementado"



retrieveHandler :: ServerRequest 'Normal RETRIEVE RETRIEVERESPONSE -> IO (ServerResponse 'Normal RETRIEVERESPONSE)
retrieveHandler _ = do
  -- Implementar o comportamento desejado ou lançar uma exceção
  error "retrieveHandler não implementado"



transferHandler :: ServerRequest 'ClientStreaming TRANSFER TRANSFEROK ->
  IO (ServerResponse 'ClientStreaming TRANSFEROK)
transferHandler _ = undefined
  -- ler a mensagem do stream: msg <- recv
  -- salvar os arquivos em uma pasta com o id do no
  -- os arquivos devem ter o nome do campo key (ou keyTest) e os bytes do arquivo
  --   devem ser os bytes do campo value
  -- Dica: você tem que fazer um 'case msg of' e testar pelos seguintes casos:
  --   Left err -> Significa que houve um erro no stream. Tratar a excecao
  --   Right (Just ...) -> Significa que a mensagem chegou corretamente e mais
  --     mensagens vao chegar
  --   Right (Nothing) -> Significa que mais nenhuma mensagem vai chegar desse
  --     stream
  -- vide publishHandler do projeto 1