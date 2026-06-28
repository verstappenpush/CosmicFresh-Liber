#!/bin/bash

# Initialize variables

GRN='\033[01;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[01;31m'
RST='\033[0m'
ORIGIN_DIR=$(pwd)
TOOLCHAIN=$ORIGIN_DIR/build-shit
NEUTRON_DIR=$TOOLCHAIN/neutron-clang
IMAGE=$ORIGIN_DIR/out/arch/arm64/boot/Image.gz
LOG=$ORIGIN_DIR/out/log.txt
DEVICE=odessa
CONFIG="${DEVICE}_defconfig"
FP_MODEL="$*"
EGIS+=(
    ./scripts/config
    --file "$ORIGIN_DIR"/out/.config
    -d FINGERPRINT_FPC_TEE_MMI
    -e CONFIG_FINGERPRINT_EGISTEC_FPS_MMI
)
MAKE_GCC+=(
    -j6
    O=out
    ARCH=arm64
    CROSS_COMPILE=aarch64-elf-
    CROSS_COMPILE_ARM32=arm-eabi-
    HOSTCC=gcc
    HOSTCXX=g++
    CC=aarch64-elf-gcc
)
MAKE_CLANG+=(
    -j6
    O=out
    ARCH=arm64
    CC=clang
    LD=ld.lld
    AR=llvm-ar
    AS=llvm-as
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    LLVM=1
    LLVM_IAS=1
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    HOSTCC=clang
    HOSTCXX=clang++
    HOSTLD=ld.lld
    HOSTLDFLAGS=-fuse-ld=lld
    KCFLAGS=-Wno-strict-prototypes
)

# export environment variables
export_env_vars() {
    export KBUILD_BUILD_USER=thiago
    export KBUILD_BUILD_HOST=amoruivas
    export ARCH=arm64

    # CCACHE
    export USE_CCACHE=1
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
    export CCACHE_NOHASHDIR="true"
}

script_echo() {
    echo "  $1"
}

exit_script() {
    kill -INT $$
}

# Aplica todos os patches necessários no fonte do kernel para compatibilidade com Clang moderno
apply_clang_patches() {
    script_echo "I: Aplicando patches de compatibilidade Clang..."

    # FIX 1: Remove -no-integrated-as do vdso32 (causa erro '/usr/bin/as: unrecognized option -EL')
    VDSO32_MK="$ORIGIN_DIR/arch/arm64/kernel/vdso32/Makefile"
    if [ -f "$VDSO32_MK" ]; then
        if grep -q "\-no-integrated-as" "$VDSO32_MK"; then
            sed -i 's/ -no-integrated-as//' "$VDSO32_MK"
            script_echo "I: [FIX 1] Removido -no-integrated-as de vdso32/Makefile"
        else
            script_echo "I: [FIX 1] vdso32/Makefile já está limpo"
        fi
    else
        script_echo "W: [FIX 1] vdso32/Makefile não encontrado, pulando..."
    fi

    # FIX 2: Remove -mno-fix-cortex-a53-843419 do arch/arm64/Makefile (flag exclusiva do GCC)
    ARM64_MK="$ORIGIN_DIR/arch/arm64/Makefile"
    if [ -f "$ARM64_MK" ]; then
        if grep -q "\-mno-fix-cortex-a53-843419" "$ARM64_MK"; then
            sed -i 's/-mno-fix-cortex-a53-843419//' "$ARM64_MK"
            script_echo "I: [FIX 2] Removido -mno-fix-cortex-a53-843419 de arch/arm64/Makefile"
        else
            script_echo "I: [FIX 2] arch/arm64/Makefile já está limpo"
        fi
    else
        script_echo "W: [FIX 2] arch/arm64/Makefile não encontrado, pulando..."
    fi

    # FIX 3: Corrige protótipo de função sem void em ce_service_legacy.c
    # (erro: -Werror,-Wstrict-prototypes em drivers/staging/qcacld-3.0)
    CE_FILE="$ORIGIN_DIR/drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/hif/src/ce/ce_service_legacy.c"
    if [ -f "$CE_FILE" ]; then
        if grep -q "ce_services_legacy()" "$CE_FILE"; then
            sed -i 's/ce_services_legacy()/ce_services_legacy(void)/g' "$CE_FILE"
            script_echo "I: [FIX 3] Corrigido protótipo ce_services_legacy() em ce_service_legacy.c"
        else
            script_echo "I: [FIX 3] ce_service_legacy.c já está correto"
        fi
    else
        script_echo "W: [FIX 3] ce_service_legacy.c não encontrado, pulando..."
    fi

    script_echo "I: Patches aplicados com sucesso"
}

choose_toolchain() {
    echo -e "${CYAN}"
    script_echo "============================================================"
    script_echo "  Selecione a toolchain para compilar:"
    script_echo "  1) GCC (KenHV gcc-arm64 + gcc-arm)"
    script_echo "  2) Neutron Clang (recomendado)"
    script_echo "============================================================"
    echo -e "${RST}"
    read -p "  Opção [1/2]: " TC_CHOICE

    case "$TC_CHOICE" in
        1) TOOLCHAIN_TYPE="GCC" ;;
        2) TOOLCHAIN_TYPE="NEUTRON" ;;
        *)
            script_echo "Opção inválida, usando Neutron Clang por padrão."
            TOOLCHAIN_TYPE="NEUTRON"
            ;;
    esac
    script_echo "Toolchain selecionada: $TOOLCHAIN_TYPE"
}

add_deps() {
    echo -e "${CYAN}"
    if [ ! -d "$TOOLCHAIN" ]; then
        script_echo "Criando pasta build-shit..."
        mkdir -p "$TOOLCHAIN"
    fi

    case "$TOOLCHAIN_TYPE" in
        GCC)
            if [ ! -d "$TOOLCHAIN/gcc-arm64" ]; then
                script_echo "Baixando GCC arm64..."
                cd "$TOOLCHAIN" || exit
                git clone https://github.com/KenHV/gcc-arm64.git --single-branch -b master --depth=1 2>&1 | sed 's/^/     /'
                git clone https://github.com/KenHV/gcc-arm.git --single-branch -b master --depth=1 2>&1 | sed 's/^/     /'
                cd "$ORIGIN_DIR" || exit
            fi
            ;;
        NEUTRON)
            if [ ! -d "$NEUTRON_DIR" ]; then
                script_echo "Baixando Neutron Clang..."
                mkdir -p "$NEUTRON_DIR"
                cd "$NEUTRON_DIR" || exit
                bash <(curl -s https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman) -S 2>&1 | sed 's/^/     /'
                cd "$ORIGIN_DIR" || exit
            fi
            ;;
    esac

    verify_toolchain_install
}

install_binutils() {
    script_echo "I: Verificando binutils de cross-compilação..."
    if ! command -v aarch64-linux-gnu-ld &>/dev/null; then
        script_echo "I: Instalando binutils-aarch64-linux-gnu..."
        sudo apt install -y binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi 2>&1 | sed 's/^/     /'
    else
        script_echo "I: binutils aarch64 já instalados"
    fi

    export PATH="/usr/aarch64-linux-gnu/bin:/usr/arm-linux-gnueabi/bin:${PATH}"
}

verify_toolchain_install() {
    script_echo " "
    case "$TOOLCHAIN_TYPE" in
        GCC)
            if [[ -d "${TOOLCHAIN}/gcc-arm64" ]]; then
                script_echo "I: GCC encontrado"
                export PATH="${TOOLCHAIN}/gcc-arm64/bin:${TOOLCHAIN}/gcc-arm/bin:${PATH}"
            else
                script_echo "E: GCC não encontrado, tentando baixar..."
                add_deps
            fi
            ;;
        NEUTRON)
            if [[ -d "${NEUTRON_DIR}" ]]; then
                script_echo "I: Neutron Clang encontrado"
                export PATH="${NEUTRON_DIR}/bin:${PATH}"
                export LD=ld.lld

                install_binutils

                CLANG_BIN=$(which clang)
                if [[ "$CLANG_BIN" != "${NEUTRON_DIR}/bin/clang" ]]; then
                    script_echo "E: clang não está apontando para o Neutron Clang!"
                    script_echo "   Esperado: ${NEUTRON_DIR}/bin/clang"
                    script_echo "   Encontrado: $CLANG_BIN"
                    exit_script
                fi
                script_echo "I: clang -> $CLANG_BIN"
            else
                script_echo "E: Neutron Clang não encontrado, tentando baixar..."
                add_deps
            fi
            ;;
    esac
}

build_kernel_image() {
    cleanup
    script_echo " "
    echo -e "${GRN}"
    read -p "  Versão do Kernel: " KV
    echo -e "${YELLOW}"
    script_echo "Building CosmicFresh Kernel For $DEVICE com $TOOLCHAIN_TYPE"

    case "$TOOLCHAIN_TYPE" in
        GCC)     MAKE=("${MAKE_GCC[@]}") ;;
        NEUTRON) MAKE=("${MAKE_CLANG[@]}") ;;
    esac

    # Aplica patches de compatibilidade Clang antes de compilar
    if [[ "$TOOLCHAIN_TYPE" == "NEUTRON" ]]; then
        apply_clang_patches
    fi

    make "${MAKE[@]}" LOCALVERSION="—CosmicFresh-R$KV" $CONFIG 2>&1 | sed 's/^/     /'

    echo -e "${GRN}"
    if [ "$FP_MODEL" = "EGIS" ]; then
        "${EGIS[@]}"
    else
        FP_MODEL="FPC"
    fi
    echo -e "${YELLOW}"

    make "${MAKE[@]}" LOCALVERSION="—CosmicFresh-R$KV" 2>&1 | sed 's/^/     /'

    make "${MAKE[@]}" dtbs 2>&1 | sed 's/^/     /'
    make "${MAKE[@]}" DTC_FLAGS="-@" dtbo.img 2>/dev/null || true

    SUCCESS=$?
    echo -e "${RST}"

    if [ $SUCCESS -eq 0 ] && [ -f "$IMAGE" ]; then
        echo -e "${GRN}"
        script_echo "------------------------------------------------------------"
        script_echo "Compilação concluída com sucesso!"
        script_echo "Image: out/arch/arm64/boot/Image.gz"
        script_echo "------------------------------------------------------------"
        build_flashable_zip
    elif [ $SUCCESS -eq 130 ]; then
        echo -e "${RED}"
        script_echo "------------------------------------------------------------"
        script_echo "Build interrompido pelo usuário."
        script_echo "------------------------------------------------------------"
        echo -e "${RST}"
    else
        echo -e "${RED}"
        script_echo "------------------------------------------------------------"
        script_echo "Compilação falhou. Verifique o log em: $LOG"
        script_echo "------------------------------------------------------------"
        echo -e "${RST}"
        cleanup
    fi
}

build_flashable_zip() {
    script_echo " "
    script_echo "I: Empacotando kernel..."
    echo -e "${GRN}"
    cp "$ORIGIN_DIR"/out/arch/arm64/boot/{Image.gz,dtbo.img} CosmicFresh/
    cp "$ORIGIN_DIR"/out/arch/arm64/boot/dts/qcom/sdmmagpie-odessa-base.dtb CosmicFresh/dtb
    cd "$ORIGIN_DIR"/CosmicFresh/ || exit
    zip -r9 "CosmicFresh-R$KV-$FP_MODEL-$TOOLCHAIN_TYPE-EROFS.zip" META-INF version anykernel.sh tools Image.gz dtb dtbo.img
    rm -rf {Image.gz,dtb,dtbo.img}
    cd "$ORIGIN_DIR" || exit
}

cleanup() {
    rm -rf "$ORIGIN_DIR"/out/arch/arm64/boot/{Image.gz,dt*}
    rm -rf "$ORIGIN_DIR"/CosmicFresh/{Image.gz,*.zip,dt*}
}

# Entry point
choose_toolchain
add_deps
export_env_vars
build_kernel_image