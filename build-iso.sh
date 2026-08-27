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
INSTALLEXTRA_FILE="$(pwd)/install-extra.sh"
ENV_FILE="$(pwd)/.env"

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
    [[ -f "$INSTALLEXTRA_FILE" ]] || err "install-extra.sh nao encontrado em $(pwd). Gere-o antes de rodar este script."
    log "OK - preseed.cfg, join-ad.sh e install-extra.sh encontrados."
}

# preseed.cfg e join-ad.sh sao templates com placeholders (__ROOT_PASSWORD__,
# __AD_DOMAIN__, etc.) para nao deixar senha/dominio do AD hardcoded no
# repositorio (que e publico). Os valores reais vem do .env (nao versionado).
load_env() {
    # Defaults so o script nao quebra pra quem ainda nao criou o .env -
    # NAO use esses valores em producao, copie .env.example para .env e ajuste.
    ROOT_PASSWORD="TROQUE_ESSA_SENHA"
    SUPORTE_PASSWORD="TROQUE_ESSA_SENHA"
    ALUNO_PASSWORD="TROQUE_ESSA_SENHA"
    AD_DOMAIN="seudominio.local"
    AD_ALLOWED_GROUP=""

    if [[ -f "$ENV_FILE" ]]; then
        log "Carregando segredos de $ENV_FILE..."
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    else
        log "AVISO: $ENV_FILE nao encontrado - usando valores placeholder padrao."
        log "         Copie .env.example para .env e ajuste ROOT_PASSWORD e SUPORTE_PASSWORD"
        log "         antes de gerar uma ISO para uso real."
    fi
}

# Escapa \, / e & para uso seguro do lado direito de um sed 's/.../.../'.
sed_escape_replacement() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[\/&]/\\&/g'
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
    log "Copiando preseed.cfg e join-ad.sh para a raiz da ISO (substituindo segredos do .env)..."

    local root_pw suporte_pw ad_domain ad_group aluno_pw_hash
    root_pw=$(sed_escape_replacement "$ROOT_PASSWORD")
    suporte_pw=$(sed_escape_replacement "$SUPORTE_PASSWORD")
    ad_domain=$(sed_escape_replacement "$AD_DOMAIN")
    ad_group=$(sed_escape_replacement "$AD_ALLOWED_GROUP")

    # O usuario "aluno" e criado via late_command (useradd + usermod -p), nao
    # via debconf, entao a senha dele precisa ir ja hasheada (SHA-512 crypt):
    # embutir a senha em texto puro dentro de um "in-target bash -c '...'"
    # exigiria escapar aspas/$/etc de forma segura contra shell injection, e
    # um hash gerado com openssl so contem [A-Za-z0-9./$], seguro dentro de
    # aspas simples sem escaping nenhum.
    aluno_pw_hash=$(openssl passwd -6 "$ALUNO_PASSWORD")
    aluno_pw_hash=$(sed_escape_replacement "$aluno_pw_hash")

    sed \
        -e "s/__ROOT_PASSWORD__/${root_pw}/g" \
        -e "s/__SUPORTE_PASSWORD__/${suporte_pw}/g" \
        -e "s/__ALUNO_PASSWORD_HASH__/${aluno_pw_hash}/g" \
        -e "s/__AD_DOMAIN__/${ad_domain}/g" \
        "$PRESEED_FILE" > "$EXTRACT_DIR/preseed.cfg"

    sed \
        -e "s/__AD_ALLOWED_GROUP__/${ad_group}/g" \
        "$JOINAD_FILE" > "$EXTRACT_DIR/join-ad.sh"

    log "Copiando install-extra.sh e logisim-evolution.deb para a raiz da ISO..."
    cp "$INSTALLEXTRA_FILE" "$EXTRACT_DIR/install-extra.sh"
    cp "$LOGISIM_DEB" "$EXTRACT_DIR/logisim-evolution.deb"
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

    # A ISO netinst original do Debian ja e "isohybrid" (bootavel tanto como
    # CD quanto via dd/Balena Etcher direto num pendrive), mas isso depende
    # de um cabecalho MBR especial nos primeiros bytes do arquivo. Remontar
    # com xorriso do zero NAO preserva esse cabecalho automaticamente - sem
    # ele, a ISO final continua bootavel como CD (por isso os testes via
    # QEMU -cdrom nunca pegaram isso), mas ferramentas como o Balena Etcher
    # recusam gravar em pendrive por nao reconhecerem uma imagem hibrida.
    # Extraimos o cabecalho (432 bytes) direto da ISO netinst original, que
    # ja o tem correto, em vez de depender do pacote isolinux so por causa
    # do isohdpfx.bin.
    local isohybrid_mbr="${WORKDIR}/isohybrid-mbr.bin"
    dd if="$ISO_NAME" bs=1 count=432 of="$isohybrid_mbr" status=none \
        || err "Falha ao extrair o cabecalho isohybrid da ISO netinst original."

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
        -isohybrid-mbr "$isohybrid_mbr" \
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
load_env
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
echo "  3. Apos a instalacao, o join-ad.sh e o install-extra.sh estarao em"
echo "     /usr/local/sbin/, prontos para o administrador executar manualmente"
echo "     com sudo."
