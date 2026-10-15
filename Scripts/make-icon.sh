#!/usr/bin/env bash
# Renders the v1 placeholder app icon (a white photo print in front of a teal glass slab, Docs/SPEC.md §2.5) and
# packs it as an .icns. The drawing lives in Sources/HMBSnapshot/AppIconArt.swift (also the harness's alert icon).
# Usage: Scripts/make-icon.sh <out.icns> [path-to-hmb-snapshot]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "make-icon: error: $*" >&2; exit 1; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: Scripts/make-icon.sh <out.icns> [hmb-snapshot]"
OUT="$1"
SNAPSHOT="${2:-}"
if [ -z "$SNAPSHOT" ]; then
    (cd "$ROOT" && swift build -c release --product hmb-snapshot >/dev/null)
    SNAPSHOT="$(cd "$ROOT" && swift build -c release --show-bin-path)/hmb-snapshot"
fi
[ -x "$SNAPSHOT" ] || die "no hmb-snapshot at $SNAPSHOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmb-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
"$SNAPSHOT" --render-icon "$WORK/AppIcon.iconset"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns -o "$OUT" "$WORK/AppIcon.iconset"
echo "make-icon: wrote $OUT"
