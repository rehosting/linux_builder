#!/bin/bash

# USAGE ./build.sh [configonly] [targetlist]
# configonly: optional string, if passed as first argument, we'll only
# update the defconfigs instead of building the kernel.
# If no targets are listed, we'll build for all

# Example: ./build.sh configonly armel mipseb mipsel mips64eb
#          ./build.sh armel
#          ./build.sh

# Is first argument present and configonly?
CONFIGONLY=""
if [ $# -gt 0 ] && [ "$1" == "configonly" ]; then
    CONFIGONLY="$1"
    shift
fi

# Now consume target list or use default
TARGETLIST=${1:-"armel mipseb mipsel mips64eb"}

set -eu

docker build -t pandare/kernel_builder .
docker run --rm -v $PWD:/app pandare/kernel_builder bash /app/_in_container_build.sh $CONFIGONLY $TARGETLIST
