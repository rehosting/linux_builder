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
	./build.sh --config-only --versions 4.10 --targets "armel mipseb mipsel mips64eb"
	./build.sh --versions 4.10
	./build.sh --targets armel
	./build.sh
EOF
}

# Default options
CONFIG_ONLY=false
VERSIONS=4.10
TARGETS="armeb armel mipseb mipsel mips64eb mips64el"

# Parse command-line arguments
for arg in "$@"; do
    case "$1" in
        --help)
            help
            exit
            ;;
        --config-only)
            CONFIG_ONLY=true
            shift # past argument
            ;;
        --versions)
            VERSIONS="$2"
            shift # past argument
            shift # past value
            ;;
        --targets)
            TARGETS="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            help
            exit 1
            ;;
    esac
done

docker build -t pandare/kernel_builder .
docker run --rm -v $PWD:/app pandare/kernel_builder bash /app/_in_container_build.sh "$CONFIG_ONLY" "$VERSIONS" "$TARGETS"
