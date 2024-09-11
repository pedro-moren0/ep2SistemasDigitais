{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module ServerSide (runServer) where

import Chord
import DHTTypes
import Network.GRPC.HighLevel.Generated
import Control.Concurrent

runServer ::
  Host ->
  Port ->
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  IO ()
runServer host port mPred mSucc = chordServer
  (handlers mPred mSucc)
  defaultServiceOptions
    { serverHost = host
    , serverPort = port
    }

handlers :: 
  MVar PredecessorNode ->
  MVar SuccessorNode ->
  Chord ServerRequest ServerResponse
handlers mPred mSucc = Chord { chordJoin = joinHandler -- TODO: descobrir como fazer o roteamento pelo anel
                 , chordRoute = routeHandler
                 , chordNewNode = newNodeHandler
                 , chordLeave = leaveHandler mPred
                 , chordNodeGone = nodeGoneHandler mSucc
                 , chordStore = storeHandler
                 , chordRetrieve = retrieveHandler
                 , chordTransfer = transferHandler
                 }

-- v0
joinHandler :: ServerRequest 'Normal JOIN JOINOK ->
  IO (ServerResponse 'Normal JOINOK)
joinHandler (ServerNormalRequest _metadata (JOIN a b c d)) = undefined --TODO: Implementar

routeHandler = undefined
newNodeHandler = undefined

leaveHandler ::
  MVar PredecessorNode ->
  ServerRequest 'Normal LEAVE LEAVEOK ->
  IO (ServerResponse 'Normal LEAVEOK)
leaveHandler
  mPred -- mPred eh uma variavel que contem o par Host e Porta
  (ServerNormalRequest _metadata (LEAVE _ predIp predPort _))
  = do
    -- pegar o predecessor: pred <- take mPred
    -- atualizar o valor de mPred com o ip e porta respondidos por LEAVE:
    --    put mPred (DHTNode predIp predPort)
    -- responder a requisicao de LEAVE:
    --    return $
    --      ServerNormalResponse (
    --        LEAVE_OK
    --        []
    --        StatusOk
    --        "uma mensagem com os detalhes"
    --      )


-- Se tiver tempo, implementar esse handler tambem. Ele eh
-- analogo ao leaveHandler, mas agora trabalhando com o mSucc
nodeGoneHandler ::
  MVar SuccessorNode ->
  ServerRequest 'Normal NODEGONE NODEGONEOK ->
  IO (ServerResponse 'Normal NODEGONEOK)
nodeGoneHandler
  mSucc
  (ServerNormalRequest _metadata (NODEGONE _ succIp succPort _))
  = undefined -- nao esquece de escrever o do!

nodeGoneHandler = undefined
storeHandler = undefined
retrieveHandler = undefined
transferHandler = undefined