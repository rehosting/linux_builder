#!/usr/bin/env bash
# Git-as-workspace: materialise a version's series as a real git tree you can
# develop in, bisect within, and rebase.
#
#   ./scripts/import-series.sh 6.13 /path/to/workdir
#
# Develop there as normal (commit on top), then run export-series.sh to write
# the series back. The committed patches remain the source of truth; this tree
# is a regenerated convenience, not a long-lived branch -- which is the whole
# point of the migration away from main_4.10 / main_6.13.
set -euo pipefail

VERSION="${1:?usage: import-series.sh <version> <workdir>}"
WORKDIR="${2:?}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$REPO_ROOT/patches"

[ -f "$PATCHES/$VERSION/series" ] || { echo "no series for $VERSION" >&2; exit 1; }

BASE_TAG=$(python3 -c "import json;print(json.load(open('$PATCHES/base.json'))['$VERSION']['tag'])")
MAJOR="${BASE_TAG%%.*}"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${BASE_TAG}.tar.xz"

mkdir -p "$WORKDIR"
if [ ! -e "$WORKDIR/Makefile" ]; then
    echo ">>> fetching $URL"
    TARBALL=$(nix-prefetch-url --print-path "$URL" 2>/dev/null | tail -1)
    echo ">>> extracting into $WORKDIR"
    tar xf "$TARBALL" -C "$WORKDIR" --strip-components=1
    git -C "$WORKDIR" init -q .
    git -C "$WORKDIR" add -A
    git -C "$WORKDIR" -c user.email=igloo@local -c user.name=igloo \
        commit -qm "linux ${BASE_TAG} (pristine upstream tarball)"
    git -C "$WORKDIR" tag "base-${BASE_TAG}"
fi

echo ">>> applying series"
while read -r p; do
    case "$p" in ''|\#*) continue ;; esac
    git -C "$WORKDIR" -c user.email=igloo@local -c user.name=igloo \
        am -q "$PATCHES/$p"
done < "$PATCHES/$VERSION/series"

echo "OK: $WORKDIR is linux ${BASE_TAG} + the IGLOO ${VERSION} series"
echo "    base tag: base-${BASE_TAG}   (export with: export-series.sh $VERSION $WORKDIR)"
