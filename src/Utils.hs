module Utils (module Utils) where

import DHTTypes

import Network.GRPC.HighLevel.Generated
import Data.Word (Word32)
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Char (ord)
import qualified Data.ByteString as BS
import Network.GRPC.LowLevel.Call (endpoint)

toPort :: Integral a => a -> Port
toPort = Port . fromIntegral

textToHost :: TL.Text -> Host
textToHost = Host . encodeUtf8 . TL.toStrict

byteStringToLText :: BS.ByteString -> TL.Text
byteStringToLText = TL.fromStrict . decodeUtf8

makeDHTNode :: TL.Text -> Word32 -> DHTNode
makeDHTNode rawIp rawPort = DHTNode (textToHost rawIp) (toPort rawPort)

hashTestFromRaw :: TL.Text -> Word32 -> Int
hashTestFromRaw rawHost rawPort = mod (sumDigits rawHost + fromIntegral rawPort) 8
  where
    sumDigits :: TL.Text -> Int
    sumDigits = sum . map ord . show

hashTestFromDHTNode :: DHTNode -> Int
hashTestFromDHTNode (DHTNode (Host host) (Port port)) =
  hashTestFromRaw (byteStringToLText host) (fromIntegral port)

-- hash utilities
-- based on https://fgiesen.wordpress.com/2015/09/24/intervals-in-modular-arithmetic/
cwDist :: Int -> Int -> Int -> Int
cwDist a b = mod (b - a)

ccwDist :: Int -> Int -> Int -> Int
ccwDist a b = mod (a - b)

-- someHash esta dentro do intervalo (predHash, myHash] mod n sse
-- ao caminharmos em sentido anti-horario no anel, alcancamos myHash antes de
-- chegar a predHash (i.e., se dCcw(myHash, someHash) < dCcw(myHash, predHash))
type Hash = Int
type MyHash = Int
type PredHash = Int
isRespTest :: Hash -> MyHash -> PredHash -> Int -> Bool
isRespTest someHash predHash myHash n =
  ccwDist myHash someHash n < ccwDist myHash predHash n

makeLogMessage :: String -> String -> TL.Text -> Word32 -> String
makeLogMessage handlerName logMsg ip port =
  "[" <> handlerName <> "] --- " <> logMsg <> " from " <> show ip <> ":" <> show port

makeClientConfig :: Host -> Port -> ClientConfig
makeClientConfig ip port = ClientConfig
  { clientServerEndpoint = endpoint ip port
  , clientArgs = []
  , clientSSLConfig = Nothing
  , clientAuthority = Nothing
  }