#!/usr/bin/env bash
# Write a development tree back out as the committed patch series.
#
#   ./scripts/export-series.sh 6.13 /path/to/workdir
#
# Regenerates patches/<version>/*.patch and the series file from every commit
# above base-<tag>. Patches whose content is byte-identical to an existing
# core/ patch keep referencing core/ rather than being duplicated per version.
set -euo pipefail

VERSION="${1:?usage: export-series.sh <version> <workdir>}"
WORKDIR="${2:?}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$REPO_ROOT/patches"
BASE_TAG=$(python3 -c "import json;print(json.load(open('$PATCHES/base.json'))['$VERSION']['tag'])")

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
git -C "$WORKDIR" format-patch --no-signature -o "$STAGE" "base-${BASE_TAG}..HEAD" >/dev/null

norm() { sed -e '/^From [0-9a-f]\{40\}/d' -e '/^index [0-9a-f]/d' -e '/^From: /d' -e '/^Date: /d' "$1"; }

rm -f "$PATCHES/$VERSION"/*.patch
: > "$PATCHES/$VERSION/series"

for f in "$STAGE"/*.patch; do
    n=$(basename "$f")
    matched=""
    for c in "$PATCHES"/core/*.patch; do
        [ -e "$c" ] || continue
        if diff -q <(norm "$f") <(norm "$c") >/dev/null 2>&1; then matched="core/$(basename "$c")"; break; fi
    done
    if [ -n "$matched" ]; then
        echo "$matched" >> "$PATCHES/$VERSION/series"
    else
        cp "$f" "$PATCHES/$VERSION/$n"
        echo "$VERSION/$n" >> "$PATCHES/$VERSION/series"
    fi
done

echo "OK: exported $(wc -l < "$PATCHES/$VERSION/series") patches for $VERSION"
echo "    verify with: ./scripts/verify-series.sh $VERSION <tarball> <fork-ref> <git-dir>"
