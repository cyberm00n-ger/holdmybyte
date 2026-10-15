#!/usr/bin/env bash
# Copies the built codecs (Vendor/xcframeworks/ and Sources/CHMBCodecs/vendor-include/) from another checkout,
# typically the main one, into this checkout or worktree with APFS clones (instant, no extra disk space).
# Usage: Scripts/link-codecs.sh <main-checkout>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "link-codecs: error: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: Scripts/link-codecs.sh <main-checkout>"
SRC="$(cd "$1" && pwd)" || die "no such directory: $1"
[ "$SRC" != "$ROOT" ] || die "source and destination are the same checkout"
[ -f "$SRC/Vendor/xcframeworks/HMBCodecs.xcframework/macos-arm64/libhmbcodecs.a" ] \
    || die "no codecs in $SRC (run Scripts/build-codecs.sh there first)"
[ -f "$SRC/Sources/CHMBCodecs/vendor-include/.complete" ] || die "incomplete vendor-include in $SRC"

# shellcheck source=/dev/null
EXPECTED="$(source "$ROOT/Vendor/codecs.lock"; echo "${OUTPUT_SHA256:-}")"
ACTUAL="$(shasum -a 256 "$SRC/Vendor/xcframeworks/HMBCodecs.xcframework/macos-arm64/libhmbcodecs.a" | cut -d' ' -f1)"
if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "link-codecs: warning: $SRC's archive ($ACTUAL) differs from this checkout's lock ($EXPECTED)" >&2
fi

mkdir -p "$ROOT/Vendor/xcframeworks"
rm -rf "$ROOT/Vendor/xcframeworks/HMBCodecs.xcframework" "$ROOT/Sources/CHMBCodecs/vendor-include"
cp -cR "$SRC/Vendor/xcframeworks/HMBCodecs.xcframework" "$ROOT/Vendor/xcframeworks/"
cp -cR "$SRC/Sources/CHMBCodecs/vendor-include" "$ROOT/Sources/CHMBCodecs/"
echo "link-codecs: cloned codecs from $SRC"
