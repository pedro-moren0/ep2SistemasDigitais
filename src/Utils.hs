module Utils (module Utils) where

import DHTTypes

import Network.GRPC.HighLevel.Generated
import Data.Word (Word32, Word64)
import qualified Data.Text.Lazy as TL
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Char (ord)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BSC8
import Network.GRPC.LowLevel.Call (endpoint)
import Data.ByteString (ByteString)
import Crypto.Hash (hashWith, SHA256(..))
import Data.ByteArray (convert)
import Data.Binary.Get (runGet, getWord64be)

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

hashTestFile :: FileName -> Int
hashTestFile = (`mod` 8) . sum . map ord

type CandidateHash = Int
type MyHash = Int
type PredHash = Int

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

isResponsible :: PredHash -> MyHash -> CandidateHash -> Bool
isResponsible predHash myHash candidateHash =
  if myHash > predHash then
     candidateHash `elem` [predHashPlus1 .. myHash]
  else
    candidateHash `elem` ([predHashPlus1 .. maxHash] ++ [0 .. myHash])

  where
    predHashPlus1 = predHash + 1
    maxHash = 7

-- reutilizando isResponsible para decidir quais arquivos deverao ser transferidos
retrieveFilesForTransfer :: PredHash -> CandidateHash -> [FileName] -> [FileName]
retrieveFilesForTransfer predHash candidateHash =
  filter (isResponsible predHash candidateHash . hashTestFile)

-- Função que gera o hash SHA-256 e converte para Word64
hashNodeID :: ByteString -> Int -> Word64
hashNodeID ip port =
    let portStr = BSC8.pack (show port)  -- Converte a porta para ByteString
        combined = BS.concat [ip, BSC8.pack ":", portStr]  -- Concatena IP, ":" e porta
        sha256Hash = convert (hashWith SHA256 combined) :: ByteString  -- Gera o hash SHA-256
    in runGet getWord64be (BL.take 8 (BL.fromStrict sha256Hash))  -- Pega os primeiros 8 bytes e converte para Word64

hashFileID :: FileName -> Word64
hashFileID fileName = hashNodeID (BSC8.pack fileName) (length fileName)