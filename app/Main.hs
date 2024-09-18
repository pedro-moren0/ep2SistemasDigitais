{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import System.Environment (getArgs)
import Text.Read (readMaybe)
import Network.GRPC.LowLevel hiding (host, port)
import Peer as P (tui)
import Data.IP (IP)
import Data.ByteString.Char8 (pack)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["localhost", port] -> case (readMaybe port :: Maybe Int) of
      Nothing -> putStrLn "Não foi possível converter o argumento fornecido em um número de porta"
      Just portNum -> P.tui (Host "localhost") (Port portNum)
    [host, port] -> case (readMaybe host :: Maybe IP, readMaybe port :: Maybe Int) of
      (Nothing, _) -> putStrLn "O IP fornecido como primeiro argumento não é válido"
      (_, Nothing) -> putStrLn "Não foi possível converter o argumento fornecido em um número de porta"
      (Just _, Just portNum) -> do
        putStrLn $ "Iniciando o peer na porta: " ++ show portNum
        P.tui (Host $ pack host) (Port portNum)
    _ -> putStrLn "Número de porta inválido ou não fornecido"