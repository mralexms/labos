#!/bin/bash
#
# install-extra.sh
# Script de execucao MANUAL pelo administrador, apos a instalacao do Debian.
# Instala software adicional que nao faz parte do preseed padrao (por
# exemplo, ferramentas que nao sao empacotadas no Debian).
#
# Uso:
#   sudo ./install-extra.sh
#
# Este script NAO roda automaticamente em nenhum momento da instalacao.
# Deve ser copiado para a maquina e executado manualmente pelo administrador
# quando a rede ja estiver confirmada como funcional.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERRO] Este script precisa ser executado como root (use sudo)."
    exit 1
fi

# ================================
# Logisim Evolution
# ================================
# Nao e empacotado no Debian (nem em bookworm, nem em trixie/sid) - o
# projeto publica um .deb self-contained (com JRE embutido) nas releases
# do GitHub.
LOGISIM_VERSION="4.1.0"
LOGISIM_DEB="logisim-evolution_${LOGISIM_VERSION}_amd64.deb"
LOGISIM_URL="https://github.com/logisim-evolution/logisim-evolution/releases/download/v${LOGISIM_VERSION}/${LOGISIM_DEB}"

install_logisim() {
    echo "=== Logisim Evolution ${LOGISIM_VERSION} ==="

    local tmp_deb
    tmp_deb="$(mktemp --suffix=.deb)"

    echo "[1/3] Baixando ${LOGISIM_DEB}..."
    wget -O "$tmp_deb" "$LOGISIM_URL"

    echo "[2/3] Instalando (apt resolve dependencias que faltarem)..."
    apt-get install -y "$tmp_deb"
    rm -f "$tmp_deb"

    echo "[3/3] Criando link em /usr/local/bin..."
    ln -sf /opt/logisim-evolution/bin/logisim-evolution /usr/local/bin/logisim-evolution

    echo "OK - Logisim Evolution instalado. Rode com: logisim-evolution"
    echo
}

install_logisim

echo "=== Instalacao extra concluida ==="
