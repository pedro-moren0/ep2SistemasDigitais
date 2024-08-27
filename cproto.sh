#! /usr/bin/bash

# Verifica se pelo menos um argumento foi fornecido
if [ "$#" -eq 0 ]; then
  echo "ERRO: Nenhum arquivo fornecido."
  exit 1
fi

# Loop para processar todos os argumentos fornecidos
for arquivo in "$@"; do
  echo "Compilando $arquivo ..."
  stack exec -- compile-proto-file --includeDir proto --proto $arquivo --out src
done
