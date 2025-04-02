#!/bin/bash

set -eu

# We want to build linux for each of our targets and versions using the config files. Linux is in /app/linux/[version]
# while our configs are at configs/[version]/[arch]. We need to set the ARCH and CROSS_COMPILE variables
# and put the binaries in /app/binaries

# Get options from build.sh
CONFIG_ONLY="$1"
VERSIONS="$2"
TARGETS="$3"
NO_STRIP="$4"
MENU_CONFIG="$5"
DIFFDEFCONFIG="$6"

echo "Config only: $CONFIG_ONLY"
echo "Versions: $VERSIONS"
echo "Targets: $TARGETS"
echo "No strip: $NO_STRIP"
echo "menuconfig: $MENU_CONFIG"
echo "diffdefconfig: $DIFFDEFCONFIG"

# Set this to update defconfigs instead of building kernel

get_cc() {
    local arch=$1
    local abi=""

    # Clear CFLAGS and KCFLAGS if they are set
    unset CFLAGS
    unset KCFLAGS

    if [[ $arch == *"arm64"* ]]; then
        abi=""
        arch="aarch64"
    elif [[ $arch == *"arm"* ]]; then
        abi="eabi"
        if [[ $arch == *"eb"* ]]; then
            export CFLAGS="-mbig-endian"
            export KCFLAGS="-mbig-endian"
        fi
        arch="arm"
    fi

    if [[ $arch == *"loongarch"* ]]; then
        echo "/opt/cross/loongarch64-linux-gcc-cross/bin/loongarch64-unknown-linux-gnu-"
    elif [[ $arch == *"powerpc"* ]]; then
        echo "/opt/cross/powerpc64-linux-musl-cross/bin/powerpc64-linux-musl-"
    elif [[ $arch == "riscv64" ]]; then
        # riscv64 linux-musl seems to run out of memory on linking so we switched
        # to the glibc version
        echo "/usr/bin/riscv64-linux-gnu-"
    else
        echo "/opt/cross/${arch}-linux-musl${abi}/bin/${arch}-linux-musl${abi}-"
    fi
}

for VERSION in $VERSIONS; do
for TARGET in $TARGETS; do
    BUILD_TARGETS="vmlinux"
    if [ $TARGET == "armel" ]; then
        BUILD_TARGETS="vmlinux zImage"
    elif [ $TARGET == "arm64" ]; then
        BUILD_TARGETS="vmlinux Image.gz"
    elif [ $TARGET == "x86_64" ]; then
        BUILD_TARGETS="vmlinux bzImage"
    elif [ $TARGET == "loongarch64" ]; then
        BUILD_TARGETS="vmlinux vmlinuz.efi"
    elif [ $TARGET == "riscv32" ]; then
        BUILD_TARGETS="vmlinux Image"
    elif [ $TARGET == "riscv64" ]; then
        BUILD_TARGETS="vmlinux Image"
    fi

    # Set short_arch based on TARGET
    short_arch=$(echo $TARGET | sed -E 's/(.*)(e[lb]|eb64)$/\1/')
    if [ "$short_arch" == "mips64" ]; then
        short_arch="mips"
    elif [ "$short_arch" == "loongarch64" ]; then
        short_arch="loongarch"
    elif [ "$short_arch" == "powerpc64" ]; then
        short_arch="powerpc"
    elif [ "$short_arch" == "riscv64" ]; then
        short_arch="riscv"
    elif [ "$short_arch" == "riscv32" ]; then
        short_arch="riscv"
    fi

    echo "Building $BUILD_TARGETS for $TARGET"

    if [ ! -f "/app/configs/${VERSION}/${TARGET}" ]; then
        echo "No config for $TARGET"
        exit 1
    fi
    mkdir -p "/tmp/build/${VERSION}/${TARGET}"
    cpp -P -undef "/app/configs/${VERSION}/${TARGET}" -o "/tmp/build/${VERSION}/${TARGET}/.config"


    # If updating configs, lint them with kernel first! This removes default options and duplicates.
    if $CONFIG_ONLY; then
      echo "Linting config for $TARGET to config_${VERSION}_${TARGET}.linted"
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ savedefconfig
      cp "/tmp/build/${VERSION}/${TARGET}/defconfig" "/app/config_${VERSION}_${TARGET}.linted"
      diff -u <(sort /tmp/build/${VERSION}/${TARGET}/.config) <(sort /tmp/build/${VERSION}/${TARGET}/defconfig | sed '/^[ #]/d')
    else
      echo "Building kernel for $TARGET"
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ olddefconfig
      if $MENU_CONFIG; then
        make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ menuconfig
        exit
      elif $DIFFDEFCONFIG; then
        cp /tmp/build/${VERSION}/${TARGET}/.config /tmp/original_config
        make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ defconfig
        /app/linux/${VERSION}/scripts/diffconfig /tmp/original_config /tmp/build/${VERSION}/${TARGET}/.config
        exit
      fi
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ $BUILD_TARGETS -j$(nproc)

      mkdir -p /kernels/$VERSION

      # Copy out zImage (if present) and vmlinux (always)
      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/zImage" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/zImage" /kernels/$VERSION/zImage.${TARGET}
      fi

      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/bzImage" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/bzImage" /kernels/$VERSION/bzImage.${TARGET}
      fi
      
      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/Image" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/Image" /kernels/$VERSION/Image.${TARGET}
      fi
      
      # Copy out Image.gz (if present) 
      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/Image.gz" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/Image.gz" /kernels/$VERSION/zImage.${TARGET}
      fi
      
      # Copy out vmlinuz.efi (if present)
      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/vmlinuz.efi" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/vmlinuz.efi" /kernels/$VERSION/vmlinuz.efi.${TARGET}
      fi
      
      cp "/tmp/build/${VERSION}/${TARGET}/vmlinux" /kernels/$VERSION/vmlinux.${TARGET}

      # Generate OSI profile
      echo "[${TARGET}]" >> /kernels/$VERSION/osi.config
      /panda/panda/plugins/osi_linux/utils/kernelinfo_gdb/run.sh \
        /kernels/$VERSION/vmlinux.${TARGET} /tmp/panda_profile.${TARGET}
      cat /tmp/panda_profile.${TARGET} >> /kernels/$VERSION/osi.config
      dwarf2json linux --elf /kernels/$VERSION/vmlinux.${TARGET} | xz -c > /kernels/$VERSION/cosi.${TARGET}.json.xz
      
      if ! $NO_STRIP; then
        # strip vmlinux     
        $(get_cc $TARGET)strip /kernels/$VERSION/vmlinux.${TARGET}
      fi
    fi
done
done

if ! $CONFIG_ONLY; then
  echo "Built by linux_builder on $(date)" > /kernels/README.txt
  tar cvf - /kernels | pigz > /app/kernels-latest.tar.gz
  chmod o+rw /app/kernels-latest.tar.gz
fi

# Ensure cache can be read/written by host
chmod -R o+rw /tmp/build
