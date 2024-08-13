#!/bin/bash

set -eu

# We want to build linux for each of our targets and versions using the config files. Linux is in /app/linux/[version]
# while our configs are at configs/[version]/[arch]. We need to set the ARCH and CROSS_COMPILE variables
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
    echo "/opt/cross/${arch}-linux-musl${abi}/bin/${arch}-linux-musl${abi}-"
}

for VERSION in $VERSIONS; do
for TARGET in $TARGETS; do
    BUILD_TARGETS="vmlinux"
    if [ $TARGET == "armel" ]; then
        BUILD_TARGETS="vmlinux zImage"
    elif [ $TARGET == "arm64" ]; then
        BUILD_TARGETS="vmlinux Image.gz"
    fi

    # Set short_arch based on TARGET
    short_arch=$(echo $TARGET | sed -E 's/(.*)(e[lb]|eb64)$/\1/')
    if [ "$short_arch" == "mips64" ]; then
        short_arch="mips"
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
      #diff -u <(sort /tmp/build/${VERSION}/${TARGET}/.config) <(sort /tmp/build/${VERSION}/${TARGET}/defconfig | sed '/^[ #]/d')
      cp "/tmp/build/${VERSION}/${TARGET}/defconfig" "/app/config_${VERSION}_${TARGET}.linted"
    else
      echo "Building kernel for $TARGET"
      if [ "$VERSION" == "2.6" ]; then
          # No support for olddefconfig, need to use yes + oldconfig
          yes "" | make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET $VERSION) O=/tmp/build/${VERSION}/${TARGET}/ oldconfig >/dev/null
          CFLAGS=""
      elif [ "$VERSION" ==  "4.10" ]; then
          # For versions before 6.7, use olddefconfig
          make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET $VERSION) O=/tmp/build/${VERSION}/${TARGET}/ olddefconfig
          CFLAGS=""
      else
          # For version 6.7 and later, use KCONFIG_ALLCONFIG with /dev/null
          make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET $VERSION) O=/tmp/build/${VERSION}/${TARGET}/ KCONFIG_ALLCONFIG=/dev/null oldconfig
          CFLAGS=""
      fi


      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ $BUILD_TARGETS -j$(nproc)

      mkdir -p /kernels/$VERSION

      # Copy out zImage (if present) and vmlinux (always)
      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/zImage" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/zImage" /kernels/$VERSION/zImage.${TARGET}
      fi
      
      # Copy out Image.gz (if present) 
      if [ -f "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/Image.gz" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/arch/${short_arch}/boot/Image.gz" /kernels/$VERSION/zImage.${TARGET}
      fi
      
      cp "/tmp/build/${VERSION}/${TARGET}/vmlinux" /kernels/$VERSION/vmlinux.${TARGET}

      # Generate OSI profile
      echo "[${TARGET}]" >> /kernels/$VERSION/osi.config
      /panda/panda/plugins/osi_linux/utils/kernelinfo_gdb/run.sh \
        /kernels/$VERSION/vmlinux.${TARGET} /tmp/panda_profile.${TARGET}
      cat /tmp/panda_profile.${TARGET} >> /kernels/$VERSION/osi.config
      
      # strip vmlinux     
      $(get_cc $TARGET)strip /kernels/$VERSION/vmlinux.${TARGET}
    fi
done
done

if ! $CONFIG_ONLY; then
  echo "Built by linux_builder on $(date)" > /kernels/README.txt
  tar cvfz /app/kernels-latest.tar.gz /kernels
  chmod o+rw /app/kernels-latest.tar.gz
fi

# Ensure cache can be read/written by host
chmod -R o+rw /tmp/build
