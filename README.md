# Chord DHT

Distributed Hash Table 

## Instalação

(As instruções de instalação se baseiam em distribuições Debian)

1. Instale o gRPC >= v1.45.0, o protobuf e o zlib para Haskell: `sudo apt install libgrpc-dev libprotobuf-dev  libghc-zlib-dev`
2. Instalar as seguintes dependências para instalação do GHCup: `sudo apt install build-essential curl libffi-dev libffi8ubuntu1 libgmp-dev libgmp10 libncurses-dev`
3. Instale o [Stack](https://docs.haskellstack.org/en/stable/) e/ou o [GHCup](https://www.haskell.org/ghcup/) (para devs: habilitar o Haskell Language Server na instalação do GHCup).
4. Garanta que a sua conta do Github possua chaves SSH associadas. Para fazer isso, siga esse passo a passo: https://chatgpt.com/share/e651d888-48df-4a1e-bcb5-80ddde349dc2

## Configuração, compilação e execução do Servidor e Cliente Haskell
1. Clone este repositório via `git clone`
2. Compile o projeto: `stack build`
3. Compile os arquivos `.proto`: `sh ./cproto.sh [ARQUIVO PROTO]...`
4. Para executar o código: `stack run <ip> <porta>`

Obs: o IP deve estar no formato IPv4 (XXX.XXX.XXX.XXX)