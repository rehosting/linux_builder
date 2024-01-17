#!/bin/bash

set -eu

# We want to build linux for each of our targets and versions using the config files. Linux is in /app/linux/[version]
# while our configs are at config.[arch]. We need to set the ARCH and CROSS_COMPILE variables
# and put the binaries in /app/binaries

# Get options from build.sh
CONFIG_ONLY="$1"
VERSIONS="$2"
TARGETS="$3"

echo "Config only: $CONFIG_ONLY"
echo "Versions: $VERSIONS"
echo "Targets: $TARGETS"

# Set this to update defconfigs instead of building kernel

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

for VERSION in $VERSIONS; do
for TARGET in $TARGETS; do
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
    make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${TARGET}/ olddefconfig

    # If updating configs, lint them with kernel first! This sorts, removes default options and duplicates.
    if $CONFIG_ONLY; then
      echo "Updating $TARGET config in place"
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${TARGET}/ savedefconfig
      cp /tmp/build/${TARGET}/defconfig /app/config.${TARGET}
      echo "Finished update for config.${TARGET}"
    else
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${TARGET}/ $BUILD_TARGETS -j$(nproc)

      mkdir -p /kernels/$VERSION

      # Copy out zImage (if present) and vmlinux (always)
      if [ -f "/tmp/build/${TARGET}/arch/${short_arch}/boot/zImage" ]; then
          cp "/tmp/build/${TARGET}/arch/${short_arch}/boot/zImage" /kernels/$VERSION/zImage.${TARGET}
      fi
      cp "/tmp/build/${TARGET}/vmlinux" /kernels/$VERSION/vmlinux.${TARGET}

      # Generate OSI profile
      echo "[${TARGET}]" >> /kernels/$VERSION/osi.config
      /panda/panda/plugins/osi_linux/utils/kernelinfo_gdb/run.sh \
        /kernels/$VERSION/vmlinux.${TARGET} /tmp/panda_profile.${TARGET}
      cat /tmp/panda_profile.${TARGET} >> /kernels/$VERSION/osi.config
    fi
done
done

if ! $CONFIG_ONLY; then
  echo "Built by linux_builder on $(date)" > /kernels/README.txt
  tar cvfz /app/kernels-latest.tar.gz /kernels
fi
