{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}

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



runServer :: Host -> Port -> MVar PredecessorNode -> MVar SuccessorNode -> IO ()
runServer host port mPred mSucc = chordServer
  (handlers (DHTNode host port) mPred mSucc)
  defaultServiceOptions
    { serverHost = host
    , serverPort = port
    }



handlers :: Me ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  Chord ServerRequest ServerResponse
handlers me mPred mSucc = Chord
  { chordJoin = joinHandler mPred mSucc
  , chordRoute = routeHandler me mPred mSucc
  , chordNewNode = newNodeHandler
  , chordLeave = leaveHandler mPred
  , chordNodeGone = nodeGoneHandler mSucc
  , chordStore = storeHandler
  , chordRetrieve = retrieveHandler
  , chordTransfer = transferHandler
  }



-- joinHandler: função que trata a requisição de JOIN
joinHandler :: MVar PredecessorNode ->
  MVar SuccessorNode ->
  ServerRequest 'Normal JOIN JOINOK ->
  IO (ServerResponse 'Normal JOINOK)
joinHandler
  mPred
  mSucc
  (ServerNormalRequest _metadata (JOIN joinId joinIp joinPort _)) = do
  -- Converte o IP e a porta do novo nó para o formato apropriado
  let newNode = DHTNode (textToHost joinIp) (toPort joinPort)

  -- Log do novo nó tentando se juntar
  putStrLn $ "Novo nó tentando se juntar: " ++ show newNode
  
  -- Obtém o estado atual do sucessor e predecessor
  currentSucc <- tryReadMVar mSucc
  currentPred <- tryReadMVar mPred
  
  case (currentSucc, currentPred) of
    -- O anel ainda não tem sucessor e predecessor, então o novo nó é o único nó
    (Nothing, Nothing) -> do
      -- Define o sucessor e o predecessor para o novo nó (ele mesmo)
      putMVar mSucc newNode
      putMVar mPred newNode
      putStrLn "Novo nó é o único nó no anel, sucessor e predecessor apontam para ele mesmo."

    -- O anel já tem um sucessor e predecessor, então o novo nó deve se integrar ao anel
    _ -> do
      -- Atualize o sucessor atual para apontar para o novo nó
      putMVar mSucc newNode
      putStrLn "Novo nó integrado ao anel como sucessor."
  
  -- Preencha o JOINOK com valores fictícios ou apropriados
  let response = JOINOK
        { joinokJoinedId = 0                 -- Substitua por um valor adequado (ID do nó que está se juntando)
        , joinokPredIp = joinIp              -- IP do predecessor
        , joinokPredPort = fromIntegral joinPort  -- Porta do predecessor
        , joinokSuccIp = joinIp              -- IP do sucessor
        , joinokSuccPort = fromIntegral joinPort  -- Porta do sucessor
        , joinokJoinedIdTest = 0             -- Substitua por um valor adequado (teste ou ID adicional, se necessário)
        }

  -- Retorne a resposta JOINOK formatada
  return $ ServerNormalResponse response [] StatusOk "join com sucesso"



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



newNodeHandler :: ServerRequest 'Normal NEWNODE NEWNODEOK -> IO (ServerResponse 'Normal NEWNODEOK)
newNodeHandler (ServerNormalRequest _metadata (NEWNODE newNodeIp newNodePort)) = do
  -- Converte o IP e a porta do novo nó para o formato apropriado
  let newNode = DHTNode (Host $ encodeUtf8 $ TL.toStrict newNodeIp) (Port $ fromIntegral newNodePort)

  -- Lógica para lidar com o novo nó (por exemplo, atualizar o sucessor ou predecessor)
  -- Isso pode variar conforme a lógica do protocolo Chord

  -- Exemplo básico (necessita ser adaptado conforme o protocolo Chord implementado)
  putStrLn "New node detected..."

  -- Retornar uma resposta de sucesso
  let response = NEWNODEOK -- Assumindo que NEWNODEOK é o tipo de resposta esperado
  return $ ServerNormalResponse response [] StatusOk ""



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



transferHandler :: ServerRequest 'ClientStreaming TRANSFER TRANSFEROK -> IO (ServerResponse 'ClientStreaming TRANSFEROK)
transferHandler _ = do
  -- Implementar o comportamento desejado ou lançar uma exceção
  error "transferHandler não implementado"
