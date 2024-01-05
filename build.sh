#!/bin/bash

TARGETLIST=${1:-"armel mipseb mipsel mips64eb"}

set -eu

docker build -t pandare/kernel_builder .
docker run --rm -v $PWD:/app pandare/kernel_builder bash /app/_in_container_build.sh $TARGETLIST
