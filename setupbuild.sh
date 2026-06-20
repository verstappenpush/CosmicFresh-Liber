#!/bin/bash
#
# setup-build-deps.sh
# Detecta a distro (Arch ou Ubuntu/Debian) e instala as dependências
# necessárias para buildar o kernel CosmicFresh (build.sh).
#
# Uso: chmod +x setup-build-deps.sh && ./setup-build-deps.sh
#

set -e

GRN='\033[01;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[01;31m'
RST='\033[0m'

info()  { echo -e "${CYAN}I:${RST} $1"; }
ok()    { echo -e "${GRN}OK:${RST} $1"; }
warn()  { echo -e "${YELLOW}W:${RST} $1"; }
err()   { echo -e "${RED}E:${RST} $1"; }

# ----------------------------------------------------------------------------
# 1. Detecção de distro
# ----------------------------------------------------------------------------
if [ ! -f /etc/os-release ]; then
    err "Não foi possível encontrar /etc/os-release. Distro não identificada."
    exit 1
fi

. /etc/os-release
DISTRO_ID="$ID"
DISTRO_LIKE="${ID_LIKE:-}"

info "Sistema detectado: $PRETTY_NAME"

PKG_MANAGER=""
if command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
elif command -v apt &>/dev/null; then
    PKG_MANAGER="apt"
else
    err "Nenhum gerenciador de pacotes suportado (pacman/apt) encontrado."
    err "Esse script suporta apenas Arch Linux e Ubuntu/Debian."
    exit 1
fi

info "Gerenciador de pacotes: $PKG_MANAGER"

# ----------------------------------------------------------------------------
# 2. Listas de dependências
# ----------------------------------------------------------------------------
# Pacotes essenciais pra compilar kernel Android (GKI/legado), com clang ou gcc:
# - build-essential / base-devel: gcc, make, etc (fallback caso precise compilar algo nativo)
# - bc, bison, flex: ferramentas usadas pelo kbuild
# - libssl-dev / openssl: necessário pra geração de certs/signing
# - libelf-dev / libelf: necessário pro módulo CONFIG_DEBUG_INFO_BTF e ferramentas de kernel
# - python3: scripts do kbuild
# - rsync: usado em alguns scripts de empacotamento
# - git: clonar toolchains (Neutron Clang, GCC do KenHV)
# - curl, wget: baixar antman/toolchains
# - zip, unzip: empacotar o flashable zip
# - cpio: usado por algumas etapas de build de initramfs
# - kmod: utilitários de módulo
# - device-tree-compiler (dtc): compilar device trees
# - lz4, zstd: compressão de imagem (Image.gz usa gzip, mas algumas vendor trees usam lz4/zstd)
# - ccache: o script já usa USE_CCACHE=1
# - binutils-aarch64 / arm cross binutils: linker/as para cross-compile (referenciado em install_binutils)

APT_PACKAGES=(
    build-essential
    bc
    bison
    flex
    libssl-dev
    libelf-dev
    python3
    python-is-python3
    rsync
    git
    curl
    wget
    zip
    unzip
    cpio
    kmod
    device-tree-compiler
    lz4
    zstd
    ccache
    binutils-aarch64-linux-gnu
    binutils-arm-linux-gnueabi
    libncurses-dev
    pahole
    u-boot-tools
)

PACMAN_PACKAGES=(
    base-devel
    bc
    bison
    flex
    openssl
    libelf
    python
    rsync
    git
    curl
    wget
    zip
    unzip
    cpio
    kmod
    dtc
    lz4
    zstd
    ccache
    aarch64-linux-gnu-binutils
    arm-none-eabi-binutils
    ncurses
    pahole
    uboot-tools
)

# ----------------------------------------------------------------------------
# 3. Instalação conforme a distro
# ----------------------------------------------------------------------------
install_apt() {
    # DEBIAN_FRONTEND=noninteractive evita prompts (ex: restart de serviços,
    # configuração de timezone) que travariam um runner do CI esperando input.
    export DEBIAN_FRONTEND=noninteractive

    info "Atualizando lista de pacotes (apt update)..."
    sudo -E apt update

    info "Instalando dependências via apt..."
    # Tenta instalar tudo de uma vez; se algum pacote não existir no repo
    # (varia entre versões do Ubuntu/Debian), cai pra instalação individual
    # ignorando o que falhar.
    if ! sudo -E apt install -y "${APT_PACKAGES[@]}"; then
        warn "Alguns pacotes falharam em lote, tentando individualmente..."
        for pkg in "${APT_PACKAGES[@]}"; do
            sudo -E apt install -y "$pkg" || warn "Não foi possível instalar: $pkg (pode não existir nesse repo, verifique manualmente se for crítico)"
        done
    fi
}

install_pacman() {
    info "Sincronizando bancos de dados do pacman..."
    sudo pacman -Sy

    info "Instalando dependências via pacman..."
    if ! sudo pacman -S --needed --noconfirm "${PACMAN_PACKAGES[@]}"; then
        warn "Alguns pacotes falharam em lote, tentando individualmente..."
        for pkg in "${PACMAN_PACKAGES[@]}"; do
            sudo pacman -S --needed --noconfirm "$pkg" || warn "Não foi possível instalar: $pkg (verifique se está no AUR, ex: aarch64-linux-gnu-binutils pode precisar de yay/paru em algumas configs)"
        done
    fi

    # binutils cross em Arch às vezes só existe no AUR dependendo do repo configurado.
    if ! pacman -Qi aarch64-linux-gnu-binutils &>/dev/null; then
        warn "aarch64-linux-gnu-binutils não encontrado nos repos oficiais."
        warn "Se você usa AUR helper (yay/paru), rode: yay -S aarch64-linux-gnu-binutils arm-linux-gnueabi-binutils"
    fi
}

case "$PKG_MANAGER" in
    apt)     install_apt ;;
    pacman)  install_pacman ;;
esac

# ----------------------------------------------------------------------------
# 4. Verificação final
# ----------------------------------------------------------------------------
echo ""
info "Verificando ferramentas essenciais..."

REQUIRED_BINS=(make gcc bc bison flex git curl wget zip dtc python3 ccache cpio kmod)
MISSING=()

for bin in "${REQUIRED_BINS[@]}"; do
    if command -v "$bin" &>/dev/null; then
        ok "$bin encontrado"
    else
        err "$bin NÃO encontrado"
        MISSING+=("$bin")
    fi
done

echo ""
if [ ${#MISSING[@]} -eq 0 ]; then
    ok "Todas as dependências básicas foram instaladas com sucesso!"
    info "Você já pode rodar o build.sh do kernel."
    info "Lembre-se: o próprio build.sh vai baixar a toolchain (GCC ou Neutron Clang) na primeira execução."
else
    err "As seguintes ferramentas ainda estão faltando: ${MISSING[*]}"
    err "Verifique manualmente os erros de instalação acima."
    exit 1
fi