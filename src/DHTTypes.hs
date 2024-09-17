module DHTTypes (module DHTTypes) where

import Network.GRPC.LowLevel.Call

data DHTNode = DHTNode { getHost :: Host, getPort :: Port}
type PredecessorNode = DHTNode
type SuccessorNode = DHTNode
type Me = DHTNode

instance Show DHTNode where
  show (DHTNode (Host h) (Port p)) =
    "DHTNode { host = " ++ show h ++ ", port = " ++ show p ++ " }"

type FileName = String