{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module ServerSide (runServer) where

import Chord
import Network.GRPC.HighLevel.Generated

runServer :: Host -> Port -> IO ()
runServer host port = chordServer
  handlers
  defaultServiceOptions
    { serverHost = host
    , serverPort = port
    }

handlers :: Chord ServerRequest ServerResponse
handlers = Chord { chordJoin = joinHandler
                 , chordRoute = routeHandler
                 , chordNewNode = newNodeHandler
                 , chordLeave = leaveHandler
                 , chordNodeGone = nodeGoneHandler
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
leaveHandler = undefined
nodeGoneHandler = undefined
storeHandler = undefined
retrieveHandler = undefined
transferHandler = undefined