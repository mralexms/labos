# Dockerfile - ambiente para rodar build-iso.sh
#
# Gera a ISO customizada do Debian (preseed + join-ad.sh) sem precisar
# instalar wget/xorriso/bsdtar/rsync na maquina host.
#
# A ISO final e gerada dentro de /output, que deve ser mapeada para uma
# pasta "output" no host (veja README.md).

FROM debian:12-slim

# UID/GID do usuario que vai rodar o build dentro do container.
# Ajuste para bater com o seu usuario no host (id -u / id -g) e evitar
# que os arquivos gerados fiquem com dono "root" na pasta output.
ARG USER_ID=1000
ARG GROUP_ID=1000

# Dependencias exigidas pelo build-iso.sh:
#   wget            -> baixar a ISO netinst do Debian e o SHA256SUMS
#   xorriso          -> remontar a ISO customizada
#   libarchive-tools -> fornece o bsdtar, usado para extrair a ISO sem sudo/mount
#   rsync            -> citado nas dependencias do script
#   coreutils        -> sha256sum/md5sum (checagem de integridade)
#   ca-certificates  -> necessario para o wget baixar via https
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        xorriso \
        libarchive-tools \
        rsync \
        coreutils \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Usuario nao-root, para os arquivos gerados na pasta mapeada "output"
# nao ficarem com dono root no host. GROUP_ID pode colidir com um grupo
# ja existente na imagem base (ex: GID 20 = "dialout" no Debian, mesmo
# numero do grupo "staff" no macOS) - nesse caso reaproveitamos o grupo
# existente em vez de tentar criar um novo com o mesmo GID.
RUN (getent group "${GROUP_ID}" > /dev/null || groupadd -g "${GROUP_ID}" builder) \
    && useradd -m -u "${USER_ID}" -g "${GROUP_ID}" -o -s /bin/bash builder

WORKDIR /app
COPY --chown=${USER_ID}:${GROUP_ID} build-iso.sh preseed.cfg join-ad.sh entrypoint.sh /app/
RUN chmod +x /app/build-iso.sh /app/join-ad.sh /app/entrypoint.sh

# Pasta onde a ISO final (e os artefatos intermediarios: ISO netinst
# baixada e a pasta iso-build/) sera escrita. Mapeie-a como volume para
# uma pasta "output" no host.
RUN mkdir -p /output && chown "${USER_ID}:${GROUP_ID}" /output
VOLUME ["/output"]

USER ${USER_ID}:${GROUP_ID}
ENTRYPOINT ["/app/entrypoint.sh"]
