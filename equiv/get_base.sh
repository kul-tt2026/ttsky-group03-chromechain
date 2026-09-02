#!/usr/bin/env bash
# Materialise the baseline RTL tree the gate compares against. BASE_REF defaults to the
# commit that was green on origin/main when this branch was cut (b5939b8).
#   usage: ./get_base.sh [ref]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REF="${1:-${BASE_REF:-b5939b8}}"
rm -rf "$HERE/base_src" "$HERE/.base_tmp"
mkdir -p "$HERE/.base_tmp"
git -C "$HERE/.." --work-tree="$HERE/.base_tmp" checkout "$REF" -- src
mv "$HERE/.base_tmp/src" "$HERE/base_src"
rm -rf "$HERE/.base_tmp"
# git checkout into a work-tree also stages the paths in the index; undo that.
git -C "$HERE/.." reset -q -- src
echo "base_src = $REF ($(git -C "$HERE/.." rev-parse --short "$REF"))"
