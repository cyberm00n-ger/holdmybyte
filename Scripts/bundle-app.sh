#!/usr/bin/env bash
# Builds build/holdmybyte.app (Docs/SPEC.md §4.2): release build, bundle layout, Info.plist, asset catalog (app icon
# and AccentColor, compiled by actool through Scripts/make-icon.sh), ad hoc signature, audits. Usage: Scripts/bundle-app.sh [--smoke]
#   --smoke   also launch the app binary for a few seconds and run the bundled `hmb --version`.
#
#   Contents/MacOS/holdmybyte
#   Contents/Helpers/hmb              (Helpers, never MacOS/: on a case-insensitive volume "hmb" and "HMB" collide)
#   Contents/Resources/Assets.car     (Liquid Glass app icon + AccentColor; Info.plist: CFBundleIconName, NSAccentColorName)
#   Contents/Resources/AppIcon.icns   (fallback icon, CFBundleIconFile)
#   Contents/Info.plist
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
die() { echo "bundle-app: error: $*" >&2; exit 1; }
SMOKE=0
for arg in "$@"; do
    case "$arg" in
        --smoke) SMOKE=1 ;;
        *) die "unknown argument $arg" ;;
    esac
done

BUNDLE_ID="eu.sebastianhaas.holdmybyte"
VERSION="2.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "bundle-app: swift build -c release (load: $(uptime | sed 's/.*load averages*: //'))"
swift build -c release --product holdmybyte
swift build -c release --product hmb
swift build -c release --product hmb-snapshot
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/holdmybyte.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/holdmybyte" "$APP/Contents/MacOS/holdmybyte"
cp "$BIN/hmb" "$APP/Contents/Helpers/hmb"
ASSETS="$ROOT/build/assets"           # Assets.car, AppIcon.icns, asset-info.plist, review/ (icon sources and renders)
rm -rf "$ASSETS"
"$ROOT/Scripts/make-icon.sh" "$ASSETS" "$BIN/hmb-snapshot"
cp "$ASSETS/Assets.car" "$ASSETS/AppIcon.icns" "$APP/Contents/Resources/"
for key in CFBundleIconName NSAccentColorName; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$ASSETS/asset-info.plist" >/dev/null 2>&1 || die "actool did not report $key"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>holdmybyte</string>
    <key>CFBundleDisplayName</key><string>holdmybyte</string>
    <key>CFBundleExecutable</key><string>holdmybyte</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>LSEnvironment</key><dict><key>MallocLargeCache</key><string>0</string></dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Sebastian Haas. Everything stays on this Mac.</string>
    <key>HMBGitCommit</key><string>$COMMIT</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.image</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist does not lint"
# The catalog must carry what Info.plist names: the AccentColor (AppKit's accent for alerts, panels and menus when the
# system accent is Multicolor) and the AppIcon.
catalog="$(xcrun assetutil --info "$APP/Contents/Resources/Assets.car")"
grep -q '"Name" : "AccentColor"' <<< "$catalog" || die "Assets.car has no AccentColor"
grep -q '"Name" : "AppIcon"' <<< "$catalog" || die "Assets.car has no AppIcon"

# Ad hoc signature, inside out (no --deep when signing).
codesign --force --sign - --identifier "$BUNDLE_ID.hmb" "$APP/Contents/Helpers/hmb"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# Audits (§4.2 item 4, §6.1 B4).
status=0
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q 'Mach-O' || continue
    libs="$(otool -L "$file" | tail -n +2 | awk '{print $1}')"
    if printf '%s\n' "$libs" | grep -E '^(/opt/homebrew|/usr/local)'; then echo "bundle-app: $file links a Homebrew library" >&2; status=1; fi
    while IFS= read -r lib; do
        [ -z "$lib" ] && continue
        case "$lib" in
            /usr/lib/*|/System/Library/*) ;;
            *) echo "bundle-app: $file loads a non-system library: $lib" >&2; status=1 ;;
        esac
    done <<< "$libs"
    if strings -a "$file" | grep -E '/opt/homebrew|/usr/local/(lib|opt|Cellar)' >/dev/null; then
        echo "bundle-app: $file contains a Homebrew path string" >&2; status=1
    fi
done < <(find "$APP" -type f -print0)
[ "$status" -eq 0 ] || die "audit failed"
codesign --verify --deep --strict --verbose=1 "$APP" || die "codesign --verify failed"

if [ "$SMOKE" -eq 1 ]; then
    "$APP/Contents/Helpers/hmb" --version
    "$APP/Contents/MacOS/holdmybyte" >/dev/null 2>&1 &
    pid=$!
    sleep 4
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"; wait "$pid" 2>/dev/null || true
        echo "bundle-app: smoke: the app launched and was still running after 4 s"
    else
        rc=0; wait "$pid" || rc=$?     # under set -e a bare failing `wait` would end the script without a message
        die "smoke: the app exited within 4 s (status $rc)"
    fi
fi

echo "bundle-app: $APP ($(du -sh "$APP" | cut -f1), build $BUILD_NUMBER, $COMMIT)"
