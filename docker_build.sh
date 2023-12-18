#!/bin/bash

TARGETLIST="armel mipseb mipsel mips64eb mips64el"

set -eu

docker build -t igloo_kernel_builder .
docker run --rm -v $PWD:/app bash /app/build.sh $TARGETLIST
