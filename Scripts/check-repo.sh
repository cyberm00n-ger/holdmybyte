#!/usr/bin/env bash
# Repository hygiene gate (Docs/SPEC.md §4, §5.5 acceptance 4, §6.1 B3/B5). Fails on:
#  - a tracked file larger than 512 KB (except under Docs/assets/);
#  - a tracked JPEG, HEIC or TIFF that carries an EXIF Make tag (i.e. a camera photo);
#  - tracked generated outputs (Snapshots/, Benchmarks/runs/, build/);
#  - unsafeFlags in Package.swift or any Swift source;
#  - a Homebrew path in Package.swift or the scripts (audit regexes and CMake's ignore list are allowed);
#  - exported _jpeg_* symbols in the built codec archive (when it exists);
#  - networking symbols or frameworks in the built binaries (when they exist; B5 allowlist below).
# Usage: Scripts/check-repo.sh [binary…]   (default binaries: build/holdmybyte.app's, else .build/release's)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
status=0
fail() { echo "check-repo: $*" >&2; status=1; }
note() { echo "check-repo: $*"; }

# Photos and large files.
while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    case "$file" in Docs/assets/*) continue ;; esac
    size=$(stat -f %z "$file")
    if [ "$size" -gt 524288 ]; then fail "tracked file larger than 512 KB: $file ($size bytes)"; fi
    case "$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')" in
        *.jpg|*.jpeg|*.heic|*.heif|*.tif|*.tiff)
            make=$(sips -g make "$file" 2>/dev/null | awk -F': ' '/make:/ {print $2}')
            if [ -n "$make" ] && [ "$make" != "<nil>" ]; then fail "camera photo (EXIF Make \"$make\") tracked: $file"; fi
            ;;
    esac
    case "$file" in
        Snapshots/*|Benchmarks/runs/*|build/*|.build/*) fail "generated output tracked: $file" ;;
    esac
done < <(git ls-files -z)

# unsafeFlags.
if git grep -n 'unsafeFlags' -- Package.swift 'Sources/*.swift' 'Sources/**/*.swift'; then fail "unsafeFlags found"; fi

# Homebrew paths in Package.swift and the scripts. Lines that grep for them (audits) and CMake's ignore list may name them.
brew_hits="$(git grep -nE '/opt/homebrew|/usr/local' -- Package.swift 'Scripts/*' | grep -vE 'grep|IGNORE_PREFIX_PATH' || true)"
if [ -n "$brew_hits" ]; then printf '%s\n' "$brew_hits" >&2; fail "Homebrew path in Package.swift or a script"; fi

# Codec archive exports (B3).
ARCHIVE="Vendor/xcframeworks/HMBCodecs.xcframework/macos-arm64/libhmbcodecs.a"
if [ -f "$ARCHIVE" ]; then
    symbols="$(mktemp)"
    nm -gU "$ARCHIVE" 2>/dev/null > "$symbols" || true
    if grep -E ' _jpeg_' "$symbols" | head -5; then fail "libjpeg API exported from $ARCHIVE"; fi
    rm -f "$symbols"
else
    note "no codec archive yet (skipping the _jpeg_ export check)"
fi

# Networking (B5): no URLSession/Network/CFNetwork use in our binaries. `nm -u` lists only what a binary references
# itself, so Foundation's own transitive use never shows up here.
binaries=("$@")
if [ "${#binaries[@]}" -eq 0 ]; then
    for candidate in build/holdmybyte.app/Contents/MacOS/holdmybyte build/holdmybyte.app/Contents/Helpers/hmb; do
        [ -f "$candidate" ] && binaries+=("$candidate")
    done
    if [ "${#binaries[@]}" -eq 0 ]; then
        for candidate in .build/release/holdmybyte .build/release/hmb; do [ -f "$candidate" ] && binaries+=("$candidate"); done
    fi
fi
NETWORK_SYMBOLS='URLSession|NSURLConnection|NSURLRequest|NSURLDownload|_nw_|CFNetwork|CFHost|CFSocket|CFStreamCreatePairWithSocket|_getaddrinfo$|_socket$|_connect$|SecTrust'
if [ "${#binaries[@]}" -eq 0 ]; then
    note "no built binaries (skipping the network audit; run Scripts/bundle-app.sh first for B5)"
fi
for binary in ${binaries[@]+"${binaries[@]}"}; do
    undefined="$(mktemp)"
    nm -u "$binary" 2>/dev/null > "$undefined" || true
    if grep -E "$NETWORK_SYMBOLS" "$undefined" | head -10; then fail "networking symbols referenced by $binary"; fi
    rm -f "$undefined"
    if otool -L "$binary" | grep -E 'Network.framework|CFNetwork.framework'; then fail "$binary links a networking framework"; fi
    note "network audit ok: $binary"
done

if [ "$status" -eq 0 ]; then echo "check-repo: ok"; fi
exit "$status"
