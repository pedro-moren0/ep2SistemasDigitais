module DHTTypes (module DHTTypes) where

import Network.GRPC.LowLevel.Call

data DHTNode = DHTNode Host Port
type PredecessorNode = DHTNode
type SuccessorNode = DHTNode
