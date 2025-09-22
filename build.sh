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
	./build.sh --extra-docker-opts "--cpus=2"
EOF
}

# Default options
CONFIG_ONLY=false
#VERSIONS="4.10 6.7"
VERSIONS="4.10"
TARGETS="armel arm64 mipseb mipsel mips64eb mips64el powerpc powerpcle powerpc64 powerpc64le loongarch64 riscv64 x86_64"
NO_STRIP=false
MENU_CONFIG=false
INTERACTIVE=
DIFFDEFCONFIG=false
KERNEL_DEVEL=true
IMAGE="rehosting/linux_builder"
EXTRA_DOCKER_OPTS=""

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
        --kernel-devel)
            KERNEL_DEVEL=true
            shift
            ;;
        --image)
            IMAGE="$2"
            shift # past flag
            shift # past value
            ;;
        --extra-docker-opts)
            EXTRA_DOCKER_OPTS="$2"
            shift # past flag
            shift # past value
            ;;
        *)
            help
            exit 1
            ;;
    esac
done

# Check if the image exists locally, build if not
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Docker image $IMAGE not found, building it..."
    docker build -t "$IMAGE" .
fi

mkdir -p cache

docker run $INTERACTIVE \
    --rm -v $PWD/cache:/tmp/build \
    -v $PWD:/app \
    $EXTRA_DOCKER_OPTS \
    "$IMAGE" \
    bash /app/_in_container_build.sh \
    "$CONFIG_ONLY" "$VERSIONS" "$TARGETS" \
    "$NO_STRIP" "$MENU_CONFIG" "$DIFFDEFCONFIG" "$KERNEL_DEVEL"