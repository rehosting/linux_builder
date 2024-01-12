#!/bin/bash

set -eu

# We want to build linux for each of our targets using the config files. Linux is in /app/linux
# while our configs are at config.[arch]. We need to set the ARCH and CROSS_COMPILE variables
# and put the binaries in /app/binaries

# If our first argument is configonly we'll only update the defconfigs
CONFIGONLY=false
if [ $# -gt 0 ] && [ "$1" == "configonly" ]; then
    CONFIGONLY=true
    shift
fi

# Arguments are a list of architectures.
# If none are set, we'll use our defaults
if [ $# -eq 0 ]; then
    TARGET_LIST="armel mipseb mipsel mips64eb"
else
    TARGET_LIST=$@
fi

echo "Configonly: $CONFIGONLY"
echo "Target_list: $TARGET_LIST"

# Set this to update defconfigs instead of building kernel

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

    # If updating configs, lint them with kernel first! This sorts, removes default options and duplicates.
    if $CONFIGONLY; then
      echo "Updating $TARGET config in place"
      make -C /app/linux ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${TARGET}/ savedefconfig
      cp /tmp/build/${TARGET}/defconfig /app/config.${TARGET}
      echo "Finished update for config.${TARGET}"
    else
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

        #/bin/dwarf2json linux --elf /kernels/vmlinux.${TARGET} \
        #| xz - > /kernels/vmlinux.${TARGET}.json.xz
    fi
done

if ! $CONFIGONLY; then
  echo "Built by linux_builder on $(date)" > /kernels/README.txt
  tar cvfz /app/kernels-latest.tar.gz /kernels
fi
