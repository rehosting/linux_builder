#!/bin/bash

set -eu

help() {
    cat >&2 <<EOF
USAGE ./build.sh [--help] [--config-only] [--no-strip] [--menuconfig] [--diffdefconfig] [--versions VERSIONS] [--targets TARGETS]

	--config-only
		Only update the defconfigs instead of building the kernel
	--no-strip
		Don't strip debug symbols from vmlinux
	--menuconfig
		Run menuconfig for kernel configuration
	--diffdefconfig
		Show differences between current and default config
	--versions VERSIONS
		Build only the specified kernel versions. By default, all versions are built.
	--targets TARGETS
		Build only for the specified targets. By default, all targets are built.

EXAMPLES
	./build.sh --config-only --versions "4.10 6.13" --targets "armel mipseb mipsel mips64eb"
	./build.sh --versions 4.10
	./build.sh --targets armel
	./build.sh --no-strip --menuconfig
	./build.sh
EOF
}

# Load version configuration
source ./versions.conf

# Default options
CONFIG_ONLY=false
NO_STRIP=false
MENU_CONFIG=false
DIFFDEFCONFIG=false
VERSIONS="$SUPPORTED_VERSIONS"
TARGETS="$ALL_TARGETS"

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
        --no-strip)
            NO_STRIP=true
            shift # past flag
            ;;
        --menuconfig)
            MENU_CONFIG=true
            shift # past flag
            ;;
        --diffdefconfig)
            DIFFDEFCONFIG=true
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

# Ensure igloo_base is available (as submodule or sibling directory)
if [ ! -d "igloo_base" ]; then
    if [ -d "../igloo_base" ]; then
        echo "Using igloo_base from ../igloo_base"
        ln -sf ../igloo_base igloo_base
    else
        echo "Error: igloo_base not found. Expected as submodule or ../igloo_base"
        echo "Maybe you need to do a git submodule update --init --recursive"
        exit 1
    fi
fi

# Get supported targets for a kernel version (filtering excludes)
get_supported_targets() {
    local version="$1"
    local exclude_var="KERNEL_${version//./_}_EXCLUDE"
    local exclude_list="${!exclude_var}"

    if [ -z "$exclude_list" ]; then
        # No exclusions, support all targets
        echo "$ALL_TARGETS"
    else
        # Filter out excluded targets
        local supported=""
        for target in $ALL_TARGETS; do
            local excluded=false
            for exclude in $exclude_list; do
                if [ "$target" = "$exclude" ]; then
                    excluded=true
                    break
                fi
            done
            if [ "$excluded" = false ]; then
                supported="$supported $target"
            fi
        done
        echo "$supported" | xargs  # trim whitespace
    fi
}

# Setup git worktrees for each version
setup_worktrees() {
    for version in $VERSIONS; do
        worktree_dir="build/$version"
        commit_var="KERNEL_${version//./_}_COMMIT"
        commit="${!commit_var}"

        if [ ! -d "$worktree_dir" ]; then
            echo "Creating worktree for $version at $commit"
            cd linux && git worktree add "../$worktree_dir" "$commit" && cd ..
        fi
    done
}

setup_worktrees

mkdir -p cache

# Use -it if we're in an interactive terminal (for ctrl+c)
DOCKER_OPTS="--rm -v $PWD/cache:/tmp/build -v $PWD:/app"
if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_OPTS="-it $DOCKER_OPTS"
fi

docker run $DOCKER_OPTS pandare/kernel_builder bash /app/_in_container_build.sh "$CONFIG_ONLY" "$VERSIONS" "$TARGETS" "$NO_STRIP" "$MENU_CONFIG" "$DIFFDEFCONFIG"
