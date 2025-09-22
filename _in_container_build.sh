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
KERNEL_DEVEL="${7:-false}"

echo "Config only: $CONFIG_ONLY"
echo "Versions: $VERSIONS"
echo "Targets: $TARGETS"
echo "No strip: $NO_STRIP"
echo "menuconfig: $MENU_CONFIG"
echo "diffdefconfig: $DIFFDEFCONFIG"

# Array to keep track of child processes
declare -a pids

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
    elif [[ "$short_arch" == "powerpc64" || "$short_arch" == "powerpc64le" || "$short_arch" == "powerpcle" ]]; then
        short_arch="powerpc"
    elif [ "$short_arch" == "riscv64" ]; then
        short_arch="riscv"
    elif [ "$short_arch" == "riscv32" ]; then
        short_arch="riscv"
    fi

    echo "Building $BUILD_TARGETS for $TARGET"

    if [ ! -f "/app/configs/${VERSION}/${TARGET}" ]; then
        echo "No config for $TARGET" avaiable for version $VERSION.
        # Only exit if there is a single version being built
        if [ "$(echo $VERSIONS | wc -w)" -eq 1 ]; then
            echo "Since only one version is being built, exiting."
            exit 1
        fi
        echo "Assuming this is fine in multi-version builds, skipping."
        continue
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

      # Always run modules_prepare to ensure headers and Module.symvers are generated
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ modules_prepare

      # Build modules to ensure Module.symvers is generated
      make -C /app/linux/$VERSION ARCH=${short_arch} CROSS_COMPILE=$(get_cc $TARGET) O=/tmp/build/${VERSION}/${TARGET}/ modules -j$(nproc)

      mkdir -p /kernels/$VERSION

      # Copy only the required boot artifact per architecture
      BOOT_SRC=""
      BOOT_DST=""
      case "$TARGET" in
        armel)
          BOOT_SRC="arch/arm/boot/zImage"; BOOT_DST="zImage.${TARGET}" ;;
        arm64)
          BOOT_SRC="arch/arm64/boot/Image.gz"; BOOT_DST="zImage.${TARGET}" ;;
        x86_64)
          BOOT_SRC="arch/x86/boot/bzImage"; BOOT_DST="bzImage.${TARGET}" ;;
        loongarch64)
          BOOT_SRC="arch/loongarch/boot/vmlinuz.efi"; BOOT_DST="vmlinuz.efi.${TARGET}" ;;
        riscv64|riscv32)
          BOOT_SRC="arch/riscv/boot/Image"; BOOT_DST="Image.${TARGET}" ;;
        *)
          BOOT_SRC=""; BOOT_DST="" ;;
      esac
      if [ -n "$BOOT_SRC" ]; then
        if [ -f "/tmp/build/${VERSION}/${TARGET}/${BOOT_SRC}" ]; then
          cp "/tmp/build/${VERSION}/${TARGET}/${BOOT_SRC}" "/kernels/$VERSION/${BOOT_DST}"
        else
          echo "Warning: Expected boot artifact not found: ${BOOT_SRC} for ${TARGET}"
        fi
      fi

      # vmlinux is needed for analysis, but only shipped if it is the deliverable (mips*/powerpc*)
      VMLINUX_SRC="/tmp/build/${VERSION}/${TARGET}/vmlinux"
      DELIVER_VMLINUX=false
      case "$TARGET" in
        mips*|powerpc*|powerpcle|powerpc64*|powerpc64le)
          DELIVER_VMLINUX=true
          ;;
      esac

    #  Launch kernel processing in subprocess
      time (
          # Generate OSI/COSI from build-tree vmlinux
          echo "[${TARGET}]" >> /kernels/$VERSION/osi.${TARGET}.config
          /extract_kernelinfo/run.sh \
            "${VMLINUX_SRC}" /tmp/panda_profile.${TARGET}
          cat /tmp/panda_profile.${TARGET} >> /kernels/$VERSION/osi.${TARGET}.config
          dwarf2json linux --elf "${VMLINUX_SRC}" | xz -c > /kernels/$VERSION/cosi.${TARGET}.json.xz

          # If vmlinux is the boot artifact for this TARGET, copy and (optionally) strip it
          if $DELIVER_VMLINUX; then
            cp "${VMLINUX_SRC}" "/kernels/$VERSION/vmlinux.${TARGET}"
            if ! $NO_STRIP; then
              $(get_cc $TARGET)strip "/kernels/$VERSION/vmlinux.${TARGET}"
            fi
          fi

          echo "Completed processing for $TARGET ($VERSION)"
      ) &
      # Store the PID of the background process
      pids+=($!)

      # Create minimal kernel-devel archive for module builds
      (
        KBUILD_DIR="/tmp/build/${VERSION}/${TARGET}"
        KERNEL_SRC="/app/linux/${VERSION}"
        OUTDIR="/minimal-devel/${TARGET}.${VERSION}"
        mkdir -p "$OUTDIR"
        # Explicitly copy .config file
        if [ -f "$KBUILD_DIR/.config" ]; then
          cp "$KBUILD_DIR/.config" "$OUTDIR/.config"
        fi
        cp "$KBUILD_DIR/Module.symvers" "$OUTDIR/" || true
        cp -r "$KERNEL_SRC/include" "$OUTDIR/" || true
        cp -r "$KBUILD_DIR/include" "$OUTDIR/" || true
        mkdir -p "$OUTDIR/arch/${short_arch}"
        cp -r "$KERNEL_SRC/arch/${short_arch}" "$OUTDIR/arch/" || true
        cp -r "$KBUILD_DIR/arch/${short_arch}" "$OUTDIR/arch/" || true
        # Remove arch/${ARCH}/boot from OUTDIR
        rm -rf "$OUTDIR/arch/${short_arch}/boot" || true
        if [ $short_arch == "x86_64" ]; then
          # MIPS has a different arch directory structure
          mkdir -p "$OUTDIR/arch/x86"
          cp -r "$KERNEL_SRC/arch/x86" "$OUTDIR/arch/" || true
          cp -r "$KBUILD_DIR/arch/x86" "$OUTDIR/arch/" || true
        fi
        cp -r "$KERNEL_SRC/scripts" "$OUTDIR/" || true
        cp -r "$KBUILD_DIR/scripts" "$OUTDIR/" || true
        cp -r "$KERNEL_SRC/tools" "$OUTDIR/" || true
        cp -r "$KBUILD_DIR/tools" "$OUTDIR/" || true
        cp "$KERNEL_SRC/Makefile" "$OUTDIR/" || true
        cp "$KERNEL_SRC/Kconfig" "$OUTDIR/" || true
        # Ensure fixdep is present for out-of-tree module builds
        cp -r "$KBUILD_DIR/scripts/" "$OUTDIR/scripts/" || true
      ) &
      
      # Store the PID of the background process
      pids+=($!)
      echo "Started background process ${pids[-1]} for $TARGET ($VERSION)"
    fi
done
done

if ! $CONFIG_ONLY; then
  echo "Waiting for all kernel processing to complete..."
  # Wait for all background processes to complete
  for pid in "${pids[@]}"; do
    wait $pid
    echo "Process $pid completed"
  done
  for VERSION in $VERSIONS; do
    cat /kernels/$VERSION/osi.*.config >> /kernels/$VERSION/osi.config
  done
  
  echo "All processes completed, creating final archive"
  echo "Built by linux_builder on $(date)" > /kernels/README.txt
  tar cvf - /kernels | pigz > /app/kernels-latest.tar.gz
  chmod o+rw /app/kernels-latest.tar.gz
fi

if [ "$KERNEL_DEVEL" = "true" ]; then
  echo "Aggregating all kernel-devel artifacts into kernel-devel-all.tar.gz..."
  
  # Create the tar directly from the minimal-devel directory using pigz for parallel compression
  tar cf - -C /minimal-devel . | pigz > /app/kernel-devel-all.tar.gz
  exit 0
fi

# Ensure cache can be read/written by host
chmod -R o+rw /tmp/build
