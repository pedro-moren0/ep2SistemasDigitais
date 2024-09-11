module Main (main) where

import System.Environment (getArgs)
import Text.Read (readMaybe)
import Network.GRPC.LowLevel
import Control.Exception (catch, SomeException)
import Peer as P (tui)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [port] -> case (readMaybe port :: Maybe Int) of
      Just portNum -> do
        putStrLn $ "Iniciando o peer na porta: " ++ show portNum
        catch (P.tui $ Port portNum) handleError
      Nothing -> putStrLn "Não foi possível converter o argumento fornecido em um número de porta"
    _ -> putStrLn "Número de porta inválido ou não fornecido"

handleError :: SomeException -> IO ()
handleError e = putStrLn $ "Ocorreu um erro: " ++ show e
