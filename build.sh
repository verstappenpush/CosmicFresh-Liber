#!/bin/bash

# Initialize variables

GRN='\033[01;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[01;31m'
RST='\033[0m'
ORIGIN_DIR=$(pwd)
TOOLCHAIN=$ORIGIN_DIR/build-shit
CLANG_DIR=$TOOLCHAIN/proton-clang
IMAGE=$ORIGIN_DIR/out/arch/arm64/boot/Image.gz
LOG=$ORIGIN_DIR/out/log.txt
DEVICE=odessa
CONFIG="${DEVICE}_defconfig"
FP_MODEL="$*"
EGIS+=(
    ./scripts/config \
        --file "$ORIGIN_DIR"/out/.config \
        -d FINGERPRINT_FPC_TEE_MMI \
        -e CONFIG_FINGERPRINT_EGISTEC_FPS_MMI
)
MAKE_GCC+=(
    -j6 \
        O=out \
        CROSS_COMPILE=aarch64-elf- \
        CROSS_COMPILE_ARM32=arm-eabi- \
        HOSTCC=gcc \
        HOSTCXX=aarch64-elf-g++ \
        CC=aarch64-elf-gcc
)
MAKE_CLANG+=(
    -j6 \
        O=out \
        ARCH=arm64 \
        CC=clang \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
        HOSTCC=clang \
        HOSTCXX=clang++
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

choose_toolchain() {
    echo -e "${CYAN}"
    script_echo "============================================================"
    script_echo "  Selecione a toolchain para compilar:"
    script_echo "  1) GCC (KenHV gcc-arm64 + gcc-arm)"
    script_echo "  2) Proton Clang"
    script_echo "============================================================"
    echo -e "${RST}"
    read -p "  Opção [1/2]: " TC_CHOICE

    case "$TC_CHOICE" in
        1)
            TOOLCHAIN_TYPE="GCC"
            ;;
        2)
            TOOLCHAIN_TYPE="CLANG"
            ;;
        *)
            script_echo "Opção inválida, usando GCC por padrão."
            TOOLCHAIN_TYPE="GCC"
            ;;
    esac
    script_echo "Toolchain selecionada: $TOOLCHAIN_TYPE"
}

add_deps() {
    echo -e "${CYAN}"
    if [ ! -d "$TOOLCHAIN" ]; then
        script_echo "Criando pasta build-shit..."
        mkdir "$TOOLCHAIN"
    fi

    if [ "$TOOLCHAIN_TYPE" = "GCC" ]; then
        if [ ! -d "$TOOLCHAIN/gcc-arm64" ]; then
            script_echo "Baixando GCC arm64..."
            cd "$TOOLCHAIN" || exit
            git clone https://github.com/KenHV/gcc-arm64.git --single-branch -b master --depth=1 2>&1 | sed 's/^/     /'
            git clone https://github.com/KenHV/gcc-arm.git --single-branch -b master --depth=1 2>&1 | sed 's/^/     /'
            cd ../
        fi
    elif [ "$TOOLCHAIN_TYPE" = "CLANG" ]; then
        if [ ! -d "$CLANG_DIR" ]; then
            script_echo "Baixando Proton Clang..."
            cd "$TOOLCHAIN" || exit
            git clone https://github.com/kdrag0n/proton-clang.git --single-branch -b master --depth=1 2>&1 | sed 's/^/     /'
            cd ../
        fi
    fi

    verify_toolchain_install
}

verify_toolchain_install() {
    script_echo " "
    if [ "$TOOLCHAIN_TYPE" = "GCC" ]; then
        if [[ -d "${TOOLCHAIN}/gcc-arm64" ]]; then
            script_echo "I: GCC encontrado"
            export PATH="${TOOLCHAIN}/gcc-arm64/bin:${TOOLCHAIN}/gcc-arm/bin:${PATH}"
        else
            script_echo "E: GCC não encontrado, tentando baixar..."
            add_deps
        fi
    elif [ "$TOOLCHAIN_TYPE" = "CLANG" ]; then
        if [[ -d "${CLANG_DIR}" ]]; then
            script_echo "I: Proton Clang encontrado"
            export PATH="${CLANG_DIR}/bin:${PATH}"
        else
            script_echo "E: Proton Clang não encontrado, tentando baixar..."
            add_deps
        fi
    fi
}

build_kernel_image() {
    cleanup
    script_echo " "
    echo -e "${GRN}"
    read -p "  Versão do Kernel: " KV
    echo -e "${YELLOW}"
    script_echo "Building CosmicFresh Kernel For $DEVICE com $TOOLCHAIN_TYPE"

    # Seleciona array de flags correto
    if [ "$TOOLCHAIN_TYPE" = "GCC" ]; then
        MAKE=("${MAKE_GCC[@]}")
    else
        MAKE=("${MAKE_CLANG[@]}")
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
    make "${MAKE[@]}" dtbs dtbo.img 2>&1 | sed 's/^/     /'

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
    elif [ $SUCCESS -eq 1 ]; then
        echo -e "${RED}"
        script_echo "------------------------------------------------------------"
        script_echo "Compilação falhou."
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
    zip -r9 "CosmicFresh-R$KV-$FP_MODEL-$TOOLCHAIN_TYPE.zip" META-INF version anykernel.sh tools Image.gz dtb dtbo.img
    rm -rf {Image.gz,dtb,dtbo.img}
    cd ../
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