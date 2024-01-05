#!/bin/bash

set -eux

# We want to build linux for each of our targets using the config files. Linux is in /app/linux
# while our configs are at config.[arch]. We need to set the ARCH and CROSS_COMPILE variables
# and put the binaries in /app/binaries

mkdir -p /kernels

get_cc() {
    local arch=$1
    local abi=""

    # Clear CFLAGS and KCFLAGS if they are set
    unset CFLAGS
    unset KCFLAGS

    if [[ $arch == *"arm"* ]]; then
        abi="eabi"
        if [[ $arch == *"eb"* ]]; then
            export CFLAGS="-mbig-endian"
            export KCFLAGS="-mbig-endian"
        fi
        arch="arm"
    fi
    echo "/opt/cross/${arch}-linux-musl${abi}/bin/${arch}-linux-musl${abi}-"
}

TARGET_LIST="armel mipsel mipseb mips64eb"
for TARGET in $TARGET_LIST; do
    BUILD_TARGETS="vmlinux"
    if [ $TARGET == "armel" ]; then
        BUILD_TARGETS="vmlinux zImage"
    fi

    # Set short_arch based on TARGET
    short_arch=$(echo $TARGET | sed -E 's/(.*)(e[lb]|eb64)$/\1/')
    if [ "$short_arch" == "mips64" ]; then
        short_arch="mips"
    fi

    echo "Building $BUILD_TARGETS for $TARGET"

    if [ ! -f "/app/config.${TARGET}" ]; then
        echo "No config for $TARGET"
        exit 1
    fi
    mkdir -p "/tmp/build/${TARGET}"
    cp "/app/config.${TARGET}" "/tmp/build/${TARGET}/.config"

    # Actually build
    echo "Building kernel for $TARGET"
    make -C /app/linux ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${TARGET}/ olddefconfig
    make -C /app/linux ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${TARGET}/ $BUILD_TARGETS -j$(nproc)

    # Copy out zImage (if present) and vmlinux (always)
    if [ -f "/tmp/build/${TARGET}/arch/${short_arch}/boot/zImage" ]; then
        cp "/tmp/build/${TARGET}/arch/${short_arch}/boot/zImage" /kernels/zImage.${TARGET}
    fi
    cp "/tmp/build/${TARGET}/vmlinux" /kernels/vmlinux.${TARGET}

	# Generate OSI profile
	echo "[${TARGET}]" >> /kernels/osi.config
	/panda/panda/plugins/osi_linux/utils/kernelinfo_gdb/run.sh \
		/kernels/vmlinux.${TARGET} /tmp/panda_profile.${TARGET}
	cat /tmp/panda_profile.${TARGET} >> /kernels/osi.config

    /dwarf2json/dwarf2json linux --elf /kernels/vmlinux.${TARGET} \
		| xz - > /kernels/vmlinux.${TARGET}.json.xz

done

echo "Built by linux_builder on $(date)" > /kernels/README.txt
tar cvfz /app/kernels-latest.tar.gz /kernels
