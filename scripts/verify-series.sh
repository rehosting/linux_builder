#!/usr/bin/env bash
# Slice 1 acceptance test.
#
# Applies patches/<version>/series to the PRISTINE kernel.org tarball and proves
# the result matches the fork branch we are replacing.
#
#   ./scripts/verify-series.sh 4.10 <tarball> <fork-ref> <git-dir>
#
# NOTE ON THE BASELINE. kernel.org release tarballs are `git archive` output and
# therefore honour .gitattributes `export-ignore`, so they are NOT byte-identical
# to the git tag: v4.10's tarball lacks .gitattributes, .get_maintainer.ignore,
# and two arch/sh linker scripts. None are build-affecting and none are touched
# by the IGLOO series.
#
# So the test is not "tree hashes are equal" (they can't be) but the stronger,
# checkable claim: the patched tree differs from the fork branch ONLY by that
# known export-ignore set. Any other path appearing in the diff is a real
# regression and fails the run.
set -euo pipefail

VERSION="${1:?usage: verify-series.sh <version> <tarball> [<fork-ref> <git-dir>]}"
TARBALL="${2:?}"
# Optional: compare against the fork branch being replaced. This is a MIGRATION
# check -- once the branches are retired there is nothing to compare to, and the
# permanent invariant CI enforces is simply "the series applies cleanly".
FORK_REF="${3:-}"
GIT_DIR="${4:-}"

# Paths upstream marks export-ignore, so they are absent from release tarballs.
# Anything else in the final diff is a genuine mismatch.
EXPORT_IGNORED='^(\.gitattributes|\.get_maintainer\.ignore|arch/sh/boot/(compressed|romimage)/vmlinux\.scr)$'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$REPO_ROOT/patches"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">>> extracting $(basename "$TARBALL")"
mkdir -p "$WORK/src"
tar xf "$TARBALL" -C "$WORK/src" --strip-components=1

cd "$WORK/src"
git init -q .
git add -A
git -c user.email=nix@local -c user.name=nix commit -qm "pristine upstream"
BASE_TREE=$(git rev-parse HEAD^{tree})
echo ">>> pristine tree: $BASE_TREE"

echo ">>> applying $(grep -cv '^\s*\(#.*\)\?$' "$PATCHES/$VERSION/series") patches"
n=0
while read -r p; do
    case "$p" in ''|\#*) continue ;; esac
    n=$((n + 1))
    if ! git -c user.email=nix@local -c user.name=nix am -q "$PATCHES/$p" 2>/dev/null; then
        echo "FAIL: patch $n did not apply: $p" >&2
        git am --abort 2>/dev/null || true
        exit 1
    fi
done < "$PATCHES/$VERSION/series"

echo ">>> patched tree: $(git rev-parse HEAD^{tree})"

if [ -z "$FORK_REF" ]; then
    echo "PASS: $n patches applied cleanly to pristine linux-${VERSION}"
    echo "      (no fork ref given; skipping migration comparison)"
    exit 0
fi

git remote add fork "$GIT_DIR"
git fetch -q --depth 60 fork "+${FORK_REF}:refs/heads/forkref"

UNEXPECTED=$(git diff --name-only forkref HEAD | grep -Ev "$EXPORT_IGNORED" || true)

if [ -z "$UNEXPECTED" ]; then
    echo "PASS: $n patches applied cleanly; tree matches $FORK_REF"
    echo "      (differs only by upstream export-ignored paths, as expected)"
else
    echo "MISMATCH: unexpected differences vs $FORK_REF:" >&2
    echo "$UNEXPECTED" >&2
    exit 1
fi
