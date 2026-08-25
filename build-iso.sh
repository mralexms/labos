#!/bin/bash
#
# build-iso.sh
#
# Baixa (se necessario) a ISO netinst do Debian, embute o preseed.cfg e o
# join-ad.sh, ajusta o boot menu (BIOS/isolinux e UEFI/grub) para oferecer
# instalacao automatizada, e gera uma nova ISO customizada.
#
# Uso:
#   ./build-iso.sh
#
# Requer neste diretorio: preseed.cfg e join-ad.sh (gerados anteriormente)
#
# Dependencias: wget, xorriso, bsdtar (pacote libarchive-tools), rsync
#   sudo apt install wget xorriso libarchive-tools rsync

set -euo pipefail

# ================================
# CONFIGURACOES - AJUSTE AQUI
# ================================
DEBIAN_VERSION="12.15.0"                # versao especifica (ajuste conforme necessario)
DEBIAN_ARCH="amd64"
ISO_NAME="debian-${DEBIAN_VERSION}-${DEBIAN_ARCH}-netinst.iso"
# Debian 12 (Bookworm) e agora "oldstable" e saiu da arvore /debian-cd/
# (que serve apenas a stable atual). As ISOs de todas as versoes de
# Bookworm ficam em /cdimage/archive/<versao>/.
ISO_URL="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VERSION}/${DEBIAN_ARCH}/iso-cd/${ISO_NAME}"
CHECKSUM_URL="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VERSION}/${DEBIAN_ARCH}/iso-cd/SHA256SUMS"

# Logisim Evolution nao e empacotado no Debian - o projeto publica um .deb
# self-contained (com JRE embutido) nas releases do GitHub.
LOGISIM_VERSION="4.1.0"
LOGISIM_DEB="logisim-evolution_${LOGISIM_VERSION}_amd64.deb"
LOGISIM_URL="https://github.com/logisim-evolution/logisim-evolution/releases/download/v${LOGISIM_VERSION}/${LOGISIM_DEB}"

WORKDIR="$(pwd)/iso-build"
EXTRACT_DIR="${WORKDIR}/extracted"
OUTPUT_ISO="$(pwd)/debian-ad-lab-custom.iso"

PRESEED_FILE="$(pwd)/preseed.cfg"
JOINAD_FILE="$(pwd)/join-ad.sh"

# ================================
# Funcoes auxiliares
# ================================
log()  { echo -e "\n[build-iso] $*"; }
err()  { echo -e "\n[ERRO] $*" >&2; exit 1; }

check_dependencies() {
    log "Verificando dependencias..."
    local missing=()
    for cmd in wget xorriso bsdtar rsync sha256sum; do
        command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Comandos ausentes: ${missing[*]}
Instale com: sudo apt install wget xorriso libarchive-tools rsync coreutils"
    fi
    log "OK - todas as dependencias presentes."
}

check_input_files() {
    [[ -f "$PRESEED_FILE" ]] || err "preseed.cfg nao encontrado em $(pwd). Gere-o antes de rodar este script."
    [[ -f "$JOINAD_FILE"  ]] || err "join-ad.sh nao encontrado em $(pwd). Gere-o antes de rodar este script."
    log "OK - preseed.cfg e join-ad.sh encontrados."
}

download_iso_if_needed() {
    if [[ -f "$ISO_NAME" ]]; then
        log "ISO ja existe localmente ($ISO_NAME). Pulando download."
    else
        log "Baixando ISO netinst do Debian ${DEBIAN_VERSION} (${DEBIAN_ARCH})..."
        wget -c "$ISO_URL" -O "$ISO_NAME" || err "Falha ao baixar a ISO. Verifique a URL/versao: $ISO_URL"
    fi

    log "Verificando checksum SHA256..."
    if wget -q "$CHECKSUM_URL" -O SHA256SUMS.tmp; then
        EXPECTED=$(grep "$ISO_NAME" SHA256SUMS.tmp | awk '{print $1}')
        ACTUAL=$(sha256sum "$ISO_NAME" | awk '{print $1}')
        rm -f SHA256SUMS.tmp
        if [[ -z "$EXPECTED" ]]; then
            log "AVISO: nao encontrei o hash esperado para $ISO_NAME no SHA256SUMS remoto. Pulando verificacao."
        elif [[ "$EXPECTED" != "$ACTUAL" ]]; then
            err "Checksum NAO confere!
  Esperado: $EXPECTED
  Obtido:   $ACTUAL
A ISO baixada pode estar corrompida ou a versao mudou. Apague $ISO_NAME e tente novamente."
        else
            log "OK - checksum confere."
        fi
    else
        log "AVISO: nao foi possivel baixar SHA256SUMS para verificar integridade. Prosseguindo sem verificar."
    fi
}

extract_iso() {
    log "Extraindo conteudo da ISO (sem precisar de sudo/mount)..."
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    bsdtar -C "$EXTRACT_DIR" -xf "$ISO_NAME" \
        || err "Falha ao extrair a ISO com bsdtar."

    # bsdtar as vezes extrai sem permissao de escrita em alguns arquivos; corrige:
    chmod -R u+w "$EXTRACT_DIR"
    log "OK - ISO extraida em $EXTRACT_DIR"
}

download_logisim_if_needed() {
    if [[ -f "$LOGISIM_DEB" ]]; then
        log "Logisim Evolution .deb ja existe localmente ($LOGISIM_DEB). Pulando download."
    else
        log "Baixando Logisim Evolution ${LOGISIM_VERSION} (.deb, nao empacotado no Debian)..."
        wget -c "$LOGISIM_URL" -O "$LOGISIM_DEB" || err "Falha ao baixar o Logisim Evolution. Verifique a URL/versao: $LOGISIM_URL"
    fi
}

embed_files() {
    log "Copiando preseed.cfg, join-ad.sh e logisim-evolution.deb para a raiz da ISO..."
    cp "$PRESEED_FILE" "$EXTRACT_DIR/preseed.cfg"
    cp "$JOINAD_FILE"  "$EXTRACT_DIR/join-ad.sh"
    cp "$LOGISIM_DEB"  "$EXTRACT_DIR/logisim-evolution.deb"
    log "OK."
}

patch_boot_menus() {
    log "Ajustando menus de boot para oferecer instalacao automatizada com preseed..."

    # --- BIOS / isolinux ---
    local isolinux_cfg="$EXTRACT_DIR/isolinux/txt.cfg"
    if [[ -f "$isolinux_cfg" ]]; then
        if ! grep -q "auto-preseed" "$isolinux_cfg"; then
            cat >> "$isolinux_cfg" <<'EOF'

label auto-preseed
    menu label ^Instalacao automatizada (AD Lab - preseed)
    kernel /install.amd/vmlinuz
    append vga=788 initrd=/install.amd/initrd.gz auto=true priority=high rootdelay=10 file=/cdrom/preseed.cfg ---
EOF
            log "OK - entrada BIOS/isolinux adicionada (label: auto-preseed)."
        else
            log "Entrada BIOS/isolinux ja existia - pulando."
        fi
    else
        log "AVISO: $isolinux_cfg nao encontrado - layout da ISO pode ter mudado de versao. Ajuste manualmente."
    fi

    # --- UEFI / grub ---
    local grub_cfg="$EXTRACT_DIR/boot/grub/grub.cfg"
    if [[ -f "$grub_cfg" ]]; then
        if ! grep -q "auto-preseed" "$grub_cfg"; then
            cat >> "$grub_cfg" <<'EOF'

menuentry 'Instalacao automatizada (AD Lab - preseed)' {
    set background_color=black
    linux    /install.amd/vmlinuz vga=788 auto=true priority=high rootdelay=10 file=/cdrom/preseed.cfg ---
    initrd   /install.amd/initrd.gz
}
EOF
            log "OK - entrada UEFI/grub adicionada (auto-preseed)."
        else
            log "Entrada UEFI/grub ja existia - pulando."
        fi
    else
        log "AVISO: $grub_cfg nao encontrado - layout da ISO pode ter mudado de versao. Ajuste manualmente."
    fi
}

regenerate_checksums() {
    log "Regenerando md5sum.txt (integridade interna da ISO)..."
    local md5file="$EXTRACT_DIR/md5sum.txt"
    if [[ -d "$EXTRACT_DIR" ]]; then
        (
            cd "$EXTRACT_DIR"
            # Sem -follow: as ISOs do Debian trazem um symlink "debian -> ."
            # na raiz (compatibilidade legada de multi-CD) que causa loop
            # infinito em find -follow. Os arquivos reais ja sao alcancados
            # pelo caminho canonico, entao nao seguir symlinks e seguro aqui.
            find . -type f ! -name 'md5sum.txt' -exec md5sum {} \; > md5sum.txt
        )
        log "OK - md5sum.txt regenerado."
    fi
}

rebuild_iso() {
    log "Remontando a ISO final com xorriso..."

    local isolinux_bin="isolinux/isolinux.bin"
    local boot_cat="isolinux/boot.cat"
    local efi_img="boot/grub/efi.img"

    [[ -f "$EXTRACT_DIR/$isolinux_bin" ]] || err "Nao encontrei $isolinux_bin dentro da ISO extraida. Verifique o layout da versao do Debian usada."

    local efi_args=()
    if [[ -f "$EXTRACT_DIR/$efi_img" ]]; then
        efi_args=(
            -eltorito-alt-boot
            -e "$efi_img"
            -no-emul-boot
            -isohybrid-gpt-basdat
        )
    else
        log "AVISO: $efi_img nao encontrado - ISO sera gerada sem boot UEFI hibrido."
    fi

    xorriso -as mkisofs \
        -r -V "Debian AD Lab Custom" \
        -o "$OUTPUT_ISO" \
        -J -l \
        -b "$isolinux_bin" \
        -c "$boot_cat" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "${efi_args[@]}" \
        "$EXTRACT_DIR" \
        || err "xorriso falhou ao gerar a ISO final."

    log "OK - ISO customizada gerada em: $OUTPUT_ISO"
}

# ================================
# Execucao
# ================================
mkdir -p "$WORKDIR"
cd "$(pwd)"

check_dependencies
check_input_files
download_iso_if_needed
download_logisim_if_needed
extract_iso
embed_files
patch_boot_menus
regenerate_checksums
rebuild_iso

log "Concluido."
echo
echo "Proximos passos:"
echo "  1. Grave a ISO em um pendrive:"
echo "       sudo dd if='$OUTPUT_ISO' of=/dev/sdX bs=4M status=progress conv=fsync"
echo "     (confira o device certo com 'lsblk' antes - dd apaga o destino sem aviso)"
echo "  2. No boot, escolha a entrada 'Instalacao automatizada (AD Lab - preseed)'"
echo "  3. Apos a instalacao, o join-ad.sh estara em /usr/local/sbin/join-ad.sh"
echo "     pronto para o administrador executar manualmente com sudo."
