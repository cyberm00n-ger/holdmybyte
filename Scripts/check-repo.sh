#!/usr/bin/env bash
# Repository hygiene gate (minimal WP0 version; WP5 extends it). Fails on:
#  - a tracked file larger than 512 KB (except under Docs/assets/);
#  - a tracked JPEG, HEIC or TIFF that carries an EXIF Make tag (i.e. a camera photo);
#  - unsafeFlags in Package.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
status=0
fail() { echo "check-repo: $*" >&2; status=1; }

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
done < <(git ls-files -z)

if grep -n 'unsafeFlags' Package.swift; then fail "unsafeFlags in Package.swift"; fi

if [ "$status" -eq 0 ]; then echo "check-repo: ok"; fi
exit "$status"
