#!/bin/bash

TARGETLIST="armel mipseb mipsel"

set -eu

docker build -t pandare/kernel_builder .
docker run --rm -v $PWD:/app pandare/kernel_builder bash /app/build.sh $TARGETLIST
