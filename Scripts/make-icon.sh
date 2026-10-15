#!/usr/bin/env bash
# Compiles the app's asset catalog into <out-dir> (Docs/SPEC.md §2.5, §4.2): the app icon, drawn in code in
# Sources/HMBSnapshot/AppIconArt.swift and written as an Icon Composer file, and the AccentColor (Tokens'
# accentMulticolor), which AppKit-drawn UI (alert default buttons, open panels, menus) uses when the system accent is
# Multicolor. actool renders the Liquid Glass icon into Assets.car and an AppIcon.icns fallback.
# Usage: Scripts/make-icon.sh <out-dir> [path-to-hmb-snapshot]
#   <out-dir> receives Assets.car, AppIcon.icns and asset-info.plist (CFBundleIconName etc.; bundle-app.sh merges it),
#   and review/ with the layer sources, AppIcon-flat.png and AppIcon-512.png (actool's rendering, for review).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "make-icon: error: $*" >&2; exit 1; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: Scripts/make-icon.sh <out-dir> [hmb-snapshot]"
OUT="$1"
SNAPSHOT="${2:-}"
if [ -z "$SNAPSHOT" ]; then
    (cd "$ROOT" && swift build -c release --product hmb-snapshot >/dev/null)
    SNAPSHOT="$(cd "$ROOT" && swift build -c release --show-bin-path)/hmb-snapshot"
fi
[ -x "$SNAPSHOT" ] || die "no hmb-snapshot at $SNAPSHOT"
xcrun --find actool >/dev/null 2>&1 || die "actool not found (needs Xcode 26 selected with xcode-select)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmb-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
"$SNAPSHOT" --render-assets "$WORK/src"
mkdir -p "$OUT"
xcrun actool --compile "$OUT" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist "$OUT/asset-info.plist" \
    --errors --warnings --output-format human-readable-text \
    "$WORK/src/AppIcon.icon" "$WORK/src/Assets.xcassets" > "$WORK/actool.log" 2>&1 \
    || { cat "$WORK/actool.log" >&2; die "actool failed"; }
if grep -E ': (error|warning):' "$WORK/actool.log" >&2; then die "actool reported problems"; fi
[ -f "$OUT/Assets.car" ] && [ -f "$OUT/AppIcon.icns" ] || die "actool wrote no Assets.car / AppIcon.icns"

mkdir -p "$OUT/review"
cp -R "$WORK/src/." "$OUT/review/"
iconutil -c iconset -o "$WORK/check.iconset" "$OUT/AppIcon.icns"
largest="$(ls -S "$WORK/check.iconset"/*.png | head -1)"
cp "$largest" "$OUT/review/AppIcon-actool.png"
echo "make-icon: wrote $OUT (Assets.car, AppIcon.icns; review/AppIcon-actool.png is actool's rendering)"
