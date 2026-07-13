#!/bin/bash

set -eux

help() {
    cat >&2 <<EOF
USAGE ./build.sh [--help] [--config-only] [--versions VERSIONS] [--targets TARGETS] [--cache-dir DIR]

	--config-only
		Only update the defconfigs instead of building the kernel
	--versions VERSIONS
		Build only the specified kernel versions. By default, all version directories under ./linux are built.
	--targets TARGETS
		Build only for the specified targets. By default, all targets are built.
	--cache-dir DIR
		Use DIR as the build cache directory (default: cache)
	--clear-cache
		Delete all contents of the cache directory and exit.

EXAMPLES
	./build.sh --config-only --versions "4.10 6.7" --targets "armel mipseb mipsel mips64eb"
	./build.sh --versions 4.10
	./build.sh --targets armel
	./build.sh
	./build.sh --extra-docker-opts "--cpus=2"
	./build.sh --cache-dir build_cache
EOF
}

# Default options
CONFIG_ONLY=false
#VERSIONS="4.10 6.7"
VERSIONS=""   # Empty => auto-detect all version directories under ./linux
TARGETS="armel arm64 mipseb mipsel mips64eb mips64el powerpc powerpcle powerpc64 powerpc64le loongarch64 riscv64 x86_64"
NO_STRIP=false
MENU_CONFIG=false
INTERACTIVE=
DIFFDEFCONFIG=false
KERNEL_DEVEL=true
IMAGE="rehosting/linux_builder"
EXTRA_DOCKER_OPTS=""
CACHE_DIR="cache"
CLEAR_CACHE=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            help
            exit
            ;;
        --clear-cache)
            CLEAR_CACHE=true
            shift
            ;;
        --config-only)
            CONFIG_ONLY=true
            shift
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
        --cache-dir)
            CACHE_DIR="$2"
            shift # past flag
            shift # past value
            ;;
        *)
            help
            exit 1
            ;;
    esac
done

# Auto-detect versions if not provided
if [[ -z "${VERSIONS// }" ]]; then
    if [[ ! -d linux ]]; then
        echo "Error: linux directory not found; cannot auto-detect versions. Use --versions." >&2
        exit 1
    fi
    mapfile -t _version_dirs < <(find linux -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -V)
    if [[ ${#_version_dirs[@]} -eq 0 ]]; then
        echo "Error: No version subdirectories found under linux/. Use --versions." >&2
        exit 1
    fi
    VERSIONS="${_version_dirs[*]}"
fi

# Resolve host cache directory path:
if [[ "$CACHE_DIR" == "cache" ]]; then
    CACHE_HOST_DIR="$PWD/cache"
else
    CACHE_HOST_DIR="$CACHE_DIR"
fi

# Bind-mount source translation for a shared Docker daemon (opt-in, pure
# no-op otherwise).
#
# Normally dockerd shares this script's mount namespace, so a bind-mount
# source path ("$PWD", the cache dir) means the same thing to the daemon as
# to us. Under a shared per-node daemon (e.g. rehosting CI's shared-docker
# runners) it does NOT: the daemon can't see this runner's per-pod workspace
# under /home/runner/_work, so "-v $PWD:/app" would mount an empty dir and the
# build would fail with "/app/_in_container_build.sh: No such file". The runner
# exports PENGUIN_HOST_MOUNT_FROM / PENGUIN_HOST_MOUNT_TO (the same mechanism
# penguin's wrapper uses) giving the daemon-visible location of that workspace.
#
# rewrite_mount() rewrites a bind source ONLY when BOTH env vars are set and
# the path is under _FROM. When they're unset — every local build and every
# GitHub-hosted runner — it returns the path unchanged, so behaviour is
# identical to before. (Sources outside _FROM, e.g. the kernel-source cache
# under /home/runner/_shared, are left as-is; the shared daemon mirrors that
# node-shared path directly.)
rewrite_mount() {
    local path="$1"
    if [[ -n "${PENGUIN_HOST_MOUNT_FROM:-}" && -n "${PENGUIN_HOST_MOUNT_TO:-}" \
          && "$path" == "${PENGUIN_HOST_MOUNT_FROM}"* ]]; then
        printf '%s' "${PENGUIN_HOST_MOUNT_TO}${path#"$PENGUIN_HOST_MOUNT_FROM"}"
    else
        printf '%s' "$path"
    fi
}
CACHE_MOUNT_SRC="$(rewrite_mount "$CACHE_HOST_DIR")"
APP_MOUNT_SRC="$(rewrite_mount "$PWD")"

if $CLEAR_CACHE; then
    docker run --rm -v "$CACHE_MOUNT_SRC":/tmp/build -v "$APP_MOUNT_SRC":/app pandare/kernel_builder /bin/bash -c "rm -rf /tmp/build/*"
    exit
fi

# Check if the image exists locally, build if not
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Docker image $IMAGE not found, building it..."
    docker build -t "$IMAGE" .
fi

mkdir -p "$CACHE_HOST_DIR"

docker run $INTERACTIVE \
    --rm -v "$CACHE_MOUNT_SRC":/tmp/build \
    -v "$APP_MOUNT_SRC":/app \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    $EXTRA_DOCKER_OPTS \
    "$IMAGE" \
    bash /app/_in_container_build.sh \
    "$CONFIG_ONLY" "$VERSIONS" "$TARGETS" \
    "$NO_STRIP" "$MENU_CONFIG" "$DIFFDEFCONFIG" "$KERNEL_DEVEL"