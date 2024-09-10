module Peer (module Peer) where

import Chord
import Control.Concurrent (forkIO, MVar, newEmptyMVar)
import Network.GRPC.LowLevel

type PortNumber = Int

tui :: PortNumber -> IO ()
tui port = do
  -- chamar join aqui
  undefined

join :: IO ()
join = do
  let
    clientConfig = undefined --TODO: implementar
    request = undefined --TODO: implementar
    response = undefined --TODO: implementar
  withGRPC $ \g -> withClient g clientConfig $ \c -> do
    undefined --TODO: implementar
