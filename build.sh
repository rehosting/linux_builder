#!/bin/bash

set -eu

help() {
    cat >&2 <<EOF
USAGE ./build.sh [--help] [--config-only] [--versions VERSIONS] [--targets TARGETS]

	--config-only
		Only update the defconfigs instead of building the kernel
	--versions VERSIONS
		Build only the specified kernel versions. By default, all versions are built.
	--targets TARGETS
		Build only for the specified targets. By default, all targets are built.

EXAMPLES
	./build.sh --config-only --versions "4.10 6.7" --targets "armel mipseb mipsel mips64eb"
	./build.sh --versions 4.10
	./build.sh --targets armel
	./build.sh
EOF
}

# Default options
CONFIG_ONLY=false
#VERSIONS="4.10 6.7"
VERSIONS="4.10"
TARGETS="armel arm64 mipseb mipsel mips64eb mips64el powerpc powerpc64 loongarch64 riscv32 riscv64 x86_64"
NO_STRIP=false
MENU_CONFIG=false
INTERACTIVE=
DIFFDEFCONFIG=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            help
            exit
            ;;
        --clear-cache)
            docker run --rm -v $PWD/cache:/tmp/build -v $PWD:/app pandare/kernel_builder /bin/bash -c "rm -r /tmp/build/*"
            exit
            ;;
        --config-only)
            CONFIG_ONLY=true
            shift # past flag
            ;;
        --versions)
            VERSIONS="$2"
            shift # past flag
            shift # past value
            ;;
        --no-strip)
            NO_STRIP=true
            shift # past flag
            ;;
        --menuconfig)
            MENU_CONFIG=true
            INTERACTIVE=-it
            shift # past flag
            ;;
        --targets)
            TARGETS="$2"
            shift # past flag
            shift # past value
            ;;
        --diffdefconfig)
            DIFFDEFCONFIG=true
            shift
            ;;
        *)
            help
            exit 1
            ;;
    esac
done

docker build -t pandare/kernel_builder .
mkdir -p cache

docker run $INTERACTIVE --rm -v $PWD/cache:/tmp/build -v $PWD:/app pandare/kernel_builder bash /app/_in_container_build.sh "$CONFIG_ONLY" "$VERSIONS" "$TARGETS" "$NO_STRIP" "$MENU_CONFIG" "$DIFFDEFCONFIG"