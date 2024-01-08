#!/bin/bash
set -eu

# CD to the parent dir of this script. It makes the relative paths sane and portable
rootdir="$(dirname $(dirname $(readlink -e "$0")))"
pushd $rootdir

if [ ! -e "./config_mgmt/make_all_common.sh" ]; then
    echo "FATAL: invalid rootdir: $rootdir"
    exit 1
fi

# Universal common
python3 config_mgmt/find_common.py config.{armel,armeb,mipsel,mipseb,mips64eb,mips64el} common_config.all

# arm32
python3 config_mgmt/find_common.py config.arme{l,b} common_config.arm32

# mips32
python3 config_mgmt/find_common.py config.mipse{l,b} common_config.mips32

# mips64
python3 config_mgmt/find_common.py config.mips64e{l,b} common_config.mips64


popd
