#!/usr/bin/env bash
# Outline of the release signing path (Docs/SPEC.md §4.2): Developer ID + Hardened Runtime + notarytool + stapler.
# The owner runs it with his own credentials; nothing here stores or prints them.
#   DEVELOPER_ID     e.g. "Developer ID Application: Sebastian Haas (TEAMID)"   (a keychain identity)
#   NOTARY_PROFILE   a keychain profile created once with `xcrun notarytool store-credentials`
# Usage: Scripts/notarize.sh [path/to/holdmybyte.app]     (default build/holdmybyte.app from Scripts/bundle-app.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/holdmybyte.app}"
die() { echo "notarize: error: $*" >&2; exit 1; }
[ -d "$APP" ] || die "no app at $APP (run Scripts/bundle-app.sh first)"
[ -n "${DEVELOPER_ID:-}" ] || die "set DEVELOPER_ID to your Developer ID Application identity"
[ -n "${NOTARY_PROFILE:-}" ] || die "set NOTARY_PROFILE to a notarytool keychain profile"

BUNDLE_ID="eu.sebastianhaas.holdmybyte"
# Inside out, Hardened Runtime, secure timestamp. No entitlements are needed (no network, no sandbox in v1).
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" --identifier "$BUNDLE_ID.hmb" "$APP/Contents/Helpers/hmb"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$(dirname "$APP")/holdmybyte-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
echo "notarize: $APP is signed, notarized and stapled"
