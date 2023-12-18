#!/bin/bash

set -eux

# We want to build linux for each of our targets using the config files. Linux is in /app/linux
# while our configs are at config.[arch]. We need to set the ARCH and CROSS_COMPILE variables
# and put the binaries in /app/binaries

# COMPILER PATHS:
#/opt/cross/i686-linux-musl
#/opt/cross/x86_64-linux-musl
#/opt/cross/mips64el-linux-musl
#/opt/cross/arm-linux-musleabi
#/opt/cross/aarch64-linux-musl

mkdir /kernels

TARGET_LIST="armel mipsel mipseb"
for TARGET in $TARGET_LIST; do
	BUILD_TARGETS="vmlinux"
    if [ $TARGET == "armel" ]; then
        export ARCH=arm
        export CROSS_COMPILE=/opt/cross/arm-linux-musleabi/bin/arm-linux-musleabi-
		BUILD_TARGETS="vmlinux zImage"
    elif [ $TARGET == "armeb" ]; then
		export CFLAGS="-mbig-endian"
		export KCFLAGS="-mbig-endian"
		export ARCH=arm
		export CROSS_COMPILE=/opt/cross/arm-linux-musleabi/bin/arm-linux-musleabi-
		BUILD_TARGETS="vmlinux zImage"
    elif [ $TARGET == "mipsel" ]; then
        export ARCH=mips
		export CROSS_COMPILE=/opt/cross/mipsel-linux-musl/bin/mipsel-linux-musl-
    elif [ $TARGET == "mipseb" ]; then
        export ARCH=mips
		export CROSS_COMPILE=/opt/cross/mips64eb-linux-musl/bin/mips64eb-linux-musl-
	else
		echo "Unknown target $TARGET"
		exit 1
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
	make -C /app/linux O=/tmp/build/${TARGET}/ olddefconfig #>> /app/build.log
	make -C /app/linux O=/tmp/build/${TARGET}/ $BUILD_TARGETS -j$(nproc) #>> /app/build.log

	# On error cat the log
	if [ $? -ne 0 ]; then
		echo "ERROR BUILDING KERNEL"
		tail -n30 /app/build.log
		exit 1
	fi

	# Copy out zImage (if present) and vmlinux (always)
	if [ -f "/tmp/build/${TARGET}/arch/${ARCH}/boot/zImage" ]; then
		cp "/tmp/build/${TARGET}/arch/${ARCH}/boot/zImage" /kernels/zImage.${TARGET}
	fi
	cp /tmp/build/${TARGET}/vmlinux /kernels/vmlinux.${TARGET}

	# Generate OSI profile
	echo "[${TARGET}]" >> /kernels/osi.config
	/panda/panda/plugins/osi_linux/utils/kernelinfo_gdb/run.sh \
		/kernels/vmlinux.${TARGET} /tmp/panda_profile.${TARGET}
	cat /tmp/panda_profile.${TARGET} /kernels/osi.config

    /dwarf2json/dwarf2json linux --elf /kernels/vmlinux.${TARGET} \
		| xz - > /kernels/vmlinux.${TARGET}.json.xz
done

echo "Built by linux_builder on $(date)" > /kernels/README.txt

tar cvfz /app/kernels-latest.tar.gz /kernels
