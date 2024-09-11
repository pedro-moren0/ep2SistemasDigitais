module Main (main) where

import System.Environment (getArgs)
import Text.Read (readMaybe)
import Network.GRPC.LowLevel

import Peer as P (tui)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [port] -> case (readMaybe port :: Maybe Int) of
      (Just portNum) -> P.tui $ Port portNum
      _ -> print "Não foi possível converter o argumento fornecido em um número de porta"
    _ -> print "Argumento inválido"