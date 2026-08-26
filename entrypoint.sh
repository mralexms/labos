#!/bin/bash
#
# entrypoint.sh
#
# Copia build-iso.sh, preseed.cfg e join-ad.sh (embutidos na imagem) para
# dentro de /output e executa o build-iso.sh a partir de la, ja que o
# script usa $(pwd) tanto para localizar os arquivos de entrada quanto
# para escrever a ISO baixada, a pasta iso-build/ e a ISO final.
#
# Resultado: tudo que o build-iso.sh gera fica dentro de /output, que deve
# estar mapeada para a pasta "output" do host.

set -euo pipefail

mkdir -p /output
cd /output

cp -f /app/build-iso.sh /app/preseed.cfg /app/join-ad.sh /app/install-extra.sh .

# .env (senhas/dados do AD) e opcional e NAO faz parte da imagem - so entra
# se o host montar o arquivo em /app/.env (ver README.md).
if [[ -f /app/.env ]]; then
    cp -f /app/.env .
fi

exec ./build-iso.sh "$@"
