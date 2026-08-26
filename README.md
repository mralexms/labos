# labIso - build-iso.sh via Docker

Ambiente Docker para rodar o `build-iso.sh` sem precisar instalar `wget`,
`xorriso`, `bsdtar` (libarchive-tools) e `rsync` diretamente na sua
maquina. O script baixa a ISO netinst do Debian, embute o `preseed.cfg` e
o `join-ad.sh`, ajusta os menus de boot (BIOS/isolinux e UEFI/grub) e gera
uma ISO customizada com instalacao automatizada.

## Pre-requisitos

- Docker instalado (Docker Desktop no macOS/Windows, ou Docker Engine no
  Linux).
- Conexao com a internet (o container baixa ~700 MB da ISO netinst do
  Debian na primeira execucao).

## Arquivos usados no build

Os arquivos abaixo, presentes na raiz deste repositorio, sao copiados
para dentro da imagem:

- `build-iso.sh`
- `preseed.cfg`
- `join-ad.sh`

Se voce editar qualquer um deles, **reconstrua a imagem** antes de rodar
novamente (passo 1 abaixo) para que as mudancas sejam incluidas.

## 0. Configurar segredos (.env)

`preseed.cfg` e `join-ad.sh` sao templates - a senha de root/suporte e os
dados do Active Directory (dominio, usuario admin) NAO ficam hardcoded
neles (o repositorio e publico). Em vez disso, ficam como placeholders
(`__ROOT_PASSWORD__`, `__AD_DOMAIN__`, etc.) substituidos em tempo de
build a partir de um arquivo `.env` local, que nunca e commitado.

```bash
cp .env.example .env
```

Edite o `.env` com os valores reais:

```
ROOT_PASSWORD=uma-senha-forte-aqui
SUPORTE_PASSWORD=outra-senha-forte-aqui
AD_DOMAIN=seudominio.local
AD_ADMIN_USER=admin_user
AD_ALLOWED_GROUP=
```

Se o `.env` nao existir, o build ainda funciona (usa os placeholders
`TROQUE_ESSA_SENHA` / `seudominio.local` como antes), mas com um aviso -
nao gere uma ISO para uso real sem configurar o `.env` primeiro.

## 1. Build da imagem

Na raiz do projeto (onde este `README.md` esta):

```bash
docker build -t labiso-builder .
```

No Linux, para que a ISO gerada fique com o dono correto (o seu usuario,
nao `root`), passe seu UID/GID:

```bash
docker build \
  --build-arg USER_ID=$(id -u) \
  --build-arg GROUP_ID=$(id -g) \
  -t labiso-builder .
```

## 2. Rodar o build

Crie (se ainda nao existir) a pasta `output` e rode o container mapeando-a
para `/output` dentro do container - e la que a ISO final sera escrita:

```bash
mkdir -p output

docker run --rm \
  -v "$(pwd)/output:/output" \
  -v "$(pwd)/.env:/app/.env:ro" \
  labiso-builder
```

(omita a segunda linha `-v` se ainda nao tiver criado o `.env` - o build
usa os placeholders padrao e avisa no log.)

O processo:

1. Baixa a ISO netinst do Debian (armazenada em `output/`, reaproveitada
   em execucoes futuras).
2. Verifica o checksum SHA256.
3. Extrai a ISO, embute `preseed.cfg` e `join-ad.sh`.
4. Ajusta os menus de boot BIOS/UEFI com a entrada de instalacao
   automatizada.
5. Remonta a ISO final com `xorriso`.

Ao final, a pasta `output/` no host tera:

```
output/
├── debian-12.15.0-amd64-netinst.iso  # ISO original baixada (cache)
├── debian-ad-lab-custom.iso          # ISO customizada gerada
├── iso-build/                        # conteudo extraido/trabalhado da ISO
├── build-iso.sh                      # copia usada no build
├── preseed.cfg                       # copia usada no build
└── join-ad.sh                        # copia usada no build
```

A ISO pronta para gravar em pendrive/USB e a
`output/debian-ad-lab-custom.iso`.

## 3. Gravar a ISO em um pendrive

Fora do container, na sua maquina (confira o device certo com `lsblk`
antes - `dd` apaga o destino sem aviso):

```bash
sudo dd if=output/debian-ad-lab-custom.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

## Notas

- O container roda como usuario nao-root (`builder`), evitando que os
  arquivos gerados fiquem com dono `root` na pasta `output` do host.
- Para forcar um novo download da ISO netinst (ex: mudou a versao no
  `build-iso.sh`), apague o arquivo `.iso` correspondente dentro de
  `output/` antes de rodar novamente.
- Para reprocessar do zero, apague `output/iso-build/` e
  `output/debian-ad-lab-custom.iso` antes de rodar novamente.

## Correcoes aplicadas ao build-iso.sh

Durante a validacao deste setup Docker, dois problemas pre-existentes no
`build-iso.sh` (nao relacionados ao Docker) impediam a geracao da ISO e
foram corrigidos:

1. **URL da ISO desatualizada**: `DEBIAN_VERSION` apontava para `12.8.0`
   na arvore `debian-cd/`, que so serve a stable atual. Como o Debian 12
   (Bookworm) virou "oldstable", suas ISOs migraram para
   `cdimage.debian.org/cdimage/archive/<versao>/`. Atualizado para
   `12.15.0` com a URL base corrigida.
2. **Loop infinito no `find -follow`**: as midias do Debian trazem um
   symlink `debian -> .` na raiz (compatibilidade legada de multi-CD).
   O `find -follow` usado para regenerar o `md5sum.txt` entrava em loop
   nesse symlink, abortando o script (via `set -e`) antes de rodar o
   `xorriso` - a ISO final nunca era gerada. Removido o `-follow` (os
   arquivos reais ja sao alcancados pelo caminho canonico).

O fluxo completo foi validado de ponta a ponta dentro do container,
gerando `debian-ad-lab-custom.iso` com sucesso.
