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
#VERSIONS="3.14 4.10 6.7"
VERSIONS="4.10"
TARGETS="armeb armel arm64 mipseb mipsel mips64eb mips64el x86_64"

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
        --targets)
            TARGETS="$2"
            shift # past flag
            shift # past value
            ;;
        *)
            help
            exit 1
            ;;
    esac
done

docker build -t pandare/kernel_builder .
mkdir -p cache
docker run --rm -v $PWD/cache:/tmp/build -v $PWD:/app pandare/kernel_builder bash /app/_in_container_build.sh "$CONFIG_ONLY" "$VERSIONS" "$TARGETS"
