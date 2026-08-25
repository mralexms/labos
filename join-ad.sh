#!/bin/bash
#
# join-ad.sh
# Script de execução MANUAL pelo administrador, apos a instalacao do Debian.
# Faz o join da maquina no dominio Active Directory via realmd/sssd.
#
# Uso:
#   sudo ./join-ad.sh
#
# Este script NAO roda automaticamente em nenhum momento da instalacao.
# Deve ser copiado para a maquina e executado manualmente pelo administrador
# quando a rede/DNS ja estiverem confirmados como corretos.

set -euo pipefail

# ================================
# CONFIGURACOES - AJUSTE AQUI
# ================================
DOMAIN="seudominio.local"          # Dominio AD (FQDN)
AD_ADMIN="admin_user"              # Usuario do AD com permissao de join
ALLOWED_GROUP=""                   # Opcional: ex "Linux-Users" para restringir login SSH/local a um grupo do AD. Deixe vazio para permitir todos os usuarios do dominio.

# ================================
# Checagens antes de comecar
# ================================
if [[ $EUID -ne 0 ]]; then
    echo "[ERRO] Este script precisa ser executado como root (use sudo)."
    exit 1
fi

echo "=== Join no Active Directory ==="
echo "Dominio alvo: $DOMAIN"
echo

echo "[1/7] Verificando conectividade e DNS do dominio..."
if ! host -t SRV _ldap._tcp."$DOMAIN" > /dev/null 2>&1; then
    echo "[ERRO] Nao foi possivel resolver os registros SRV do dominio."
    echo "        Verifique se o DNS desta maquina aponta para o DNS do AD"
    echo "        (nao pode ser DNS publico tipo 8.8.8.8)."
    echo "        Confira com: cat /etc/resolv.conf"
    exit 1
fi
echo "    OK - DNS resolvendo registros do dominio."
echo

echo "[2/7] Verificando sincronizacao de horario (Kerberos e sensivel a isso)..."
if command -v timedatectl > /dev/null 2>&1; then
    timedatectl status | grep -E "NTP service|synchronized" || true
fi
echo "    Se o horario nao estiver sincronizado, corrija antes de continuar"
echo "    (o join pode falhar silenciosamente com erro de Kerberos)."
echo

read -p "Confirma que DNS e horario estao corretos? Continuar? [s/N] " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Abortado pelo administrador."
    exit 0
fi
echo

echo "[3/7] Descobrindo o dominio ($DOMAIN)..."
realm discover "$DOMAIN"
echo

echo "[4/7] Executando o join no dominio..."
echo "      Sera solicitada a senha do usuario administrativo do AD: $AD_ADMIN"
realm join --user="$AD_ADMIN" "$DOMAIN"
echo "    OK - Join realizado com sucesso."
echo

echo "[5/7] Ajustando configuracao do SSSD (login com nome curto, home automatico)..."
SSSD_CONF="/etc/sssd/sssd.conf"

# Login sem precisar do FQDN (ex: "usuario" em vez de "usuario@seudominio.local")
sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' "$SSSD_CONF"

# Home directory padronizado
if ! grep -q "^fallback_homedir" "$SSSD_CONF"; then
    sed -i "/\[domain\/$DOMAIN\]/a fallback_homedir = /home/%u" "$SSSD_CONF"
else
    sed -i "s#^fallback_homedir.*#fallback_homedir = /home/%u#" "$SSSD_CONF"
fi

# Shell padrao para usuarios do AD sem shell definida no AD
if ! grep -q "^default_shell" "$SSSD_CONF"; then
    sed -i "/\[domain\/$DOMAIN\]/a default_shell = /bin/bash" "$SSSD_CONF"
fi

# Restringir a um grupo especifico do AD, se configurado acima
if [[ -n "$ALLOWED_GROUP" ]]; then
    echo "    Restringindo acesso ao grupo AD: $ALLOWED_GROUP"
    if ! grep -q "^ad_access_filter" "$SSSD_CONF"; then
        sed -i "/\[domain\/$DOMAIN\]/a ad_access_filter = (memberOf=cn=$ALLOWED_GROUP,cn=Users,dc=${DOMAIN//./,dc=})" "$SSSD_CONF"
    fi
    sed -i 's/^access_provider.*/access_provider = ad/' "$SSSD_CONF"
fi

chmod 600 "$SSSD_CONF"
echo "    OK - sssd.conf ajustado."
echo

echo "[6/7] Habilitando criacao automatica de home directory no primeiro login..."
pam-auth-update --enable mkhomedir
echo "    OK."
echo

echo "[7/7] Reiniciando servicos..."
systemctl enable sssd oddjobd
systemctl restart sssd oddjobd
echo "    OK - sssd e oddjobd reiniciados e habilitados no boot."
echo

echo "=== Join concluido ==="
echo
echo "Teste com um usuario do dominio, por exemplo:"
echo "    id nome.usuario"
echo "    getent passwd nome.usuario"
echo
echo "Se 'id' nao retornar o usuario, verifique:"
echo "    - journalctl -u sssd -f     (logs em tempo real)"
echo "    - realm list                (confirma que o join foi persistido)"
echo "    - klist -k                  (confirma o keytab da maquina)"
