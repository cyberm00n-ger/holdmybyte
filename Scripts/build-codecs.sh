#!/usr/bin/env bash
# Builds libjxl (with jpegli) and libwebp from the pinned sources in Vendor/codecs.lock into
# Vendor/xcframeworks/HMBCodecs.xcframework (one static library, no headers) and copies the
# headers listed in Scripts/codec-headers.txt into Sources/CHMBCodecs/vendor-include/.
# Idempotent: exits immediately when the existing output matches OUTPUT_SHA256 in the lock.
# See Docs/SPEC.md §3.13.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${HMB_CODEC_WORK:-$ROOT/.codec-build}"
LOCK="$ROOT/Vendor/codecs.lock"
XCF="$ROOT/Vendor/xcframeworks/HMBCodecs.xcframework"
INCLUDE_OUT="$ROOT/Sources/CHMBCodecs/vendor-include"
LIB_IN_XCF="$XCF/macos-arm64/libhmbcodecs.a"

die() { echo "build-codecs: error: $*" >&2; exit 1; }
log() { echo "build-codecs: $*" >&2; }

# shellcheck source=/dev/null
source "$LOCK"   # LIBJXL_TAG, LIBJXL_COMMIT, LIBWEBP_TAG, LIBWEBP_COMMIT, OUTPUT_SHA256

current_sha() { shasum -a 256 "$LIB_IN_XCF" 2>/dev/null | cut -d' ' -f1 || true; }

if [ -n "${OUTPUT_SHA256:-}" ] && [ "$(current_sha)" = "$OUTPUT_SHA256" ] \
   && [ -f "$INCLUDE_OUT/.complete" ] && [ "${HMB_CODEC_FORCE:-0}" != "1" ]; then
    log "up to date ($OUTPUT_SHA256)"
    exit 0
fi

for tool in git cmake ninja libtool xcodebuild nm otool shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

# Deterministic archives (no timestamps in ar headers).
export ZERO_AR_DATE=1
mkdir -p "$WORK"

fetch() { # url tag dir commit
    local url="$1" tag="$2" dir="$3" commit="$4"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ]; then
        log "reusing $dir"
    else
        rm -rf "$dir"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dir"
    fi
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "pin mismatch $dir"
}

fetch https://github.com/libjxl/libjxl.git "$LIBJXL_TAG" "$WORK/libjxl" "$LIBJXL_COMMIT"
git -C "$WORK/libjxl" submodule update --init --recursive --depth 1
fetch https://github.com/webmproject/libwebp.git "$LIBWEBP_TAG" "$WORK/libwebp" "$LIBWEBP_COMMIT"

COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_FIND_FRAMEWORK=NEVER
        "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
        # Reproducible output: no absolute checkout paths in __FILE__ strings.
        "-DCMAKE_C_FLAGS=-ffile-prefix-map=$WORK=/hmb-codecs"
        "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$WORK=/hmb-codecs")

log "configuring libjxl $LIBJXL_TAG"
cmake -S "$WORK/libjxl" -B "$WORK/jxl-build" "${COMMON[@]}" -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_JPEGLI=ON \
      -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
      -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
      -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF
log "building libjxl"
cmake --build "$WORK/jxl-build"
# jpegli-static is EXCLUDE_FROM_ALL upstream; build it explicitly.
cmake --build "$WORK/jxl-build" --target jpegli-static

log "configuring libwebp $LIBWEBP_TAG"
cmake -S "$WORK/libwebp" -B "$WORK/webp-build" "${COMMON[@]}" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
      -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
      -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_USE_THREAD=ON
log "building libwebp"
cmake --build "$WORK/webp-build"

# Resolve a "<ROOTVAR> <relative path>" pair from the list files.
resolve_root() {
    case "$1" in
        JXL_SRC) echo "$WORK/libjxl" ;;
        JXL_BUILD) echo "$WORK/jxl-build" ;;
        WEBP_SRC) echo "$WORK/libwebp" ;;
        WEBP_BUILD) echo "$WORK/webp-build" ;;
        *) die "unknown root '$1'" ;;
    esac
}

LIBS=()
while read -r root rel _; do
    case "$root" in ''|'#'*) continue ;; esac
    lib="$(resolve_root "$root")/$rel"
    [ -f "$lib" ] || die "missing library $lib"
    LIBS+=("$lib")
done < "$ROOT/Scripts/codec-libs.txt"
[ "${#LIBS[@]}" -gt 0 ] || die "Scripts/codec-libs.txt lists no libraries"

log "merging ${#LIBS[@]} archives"
rm -f "$WORK/libhmbcodecs.a"
libtool -static -no_warning_for_no_symbols -o "$WORK/libhmbcodecs.a" "${LIBS[@]}"

log "auditing"
# (symbol table captured to a file: `nm | grep -q` would SIGPIPE nm under pipefail)
SYMS="$WORK/libhmbcodecs.syms"
nm -gU "$WORK/libhmbcodecs.a" > "$SYMS" 2>/dev/null
if grep -E ' _jpeg_' "$SYMS"; then die "libjpeg API exported"; fi
for sym in jpegli_CreateCompress jpegli_set_distance JxlEncoderCreate JxlDecoderCreate JxlThreadParallelRunner \
           WebPEncode WebPNewInternal SharpYuvConvert; do
    grep -qE " _${sym}\$" "$SYMS" || die "symbol _$sym missing from the archive"
done
if otool -l "$WORK/libhmbcodecs.a" 2>/dev/null | grep -E '/opt/homebrew|/usr/local'; then die "Homebrew path in a load command"; fi
if strings -a "$WORK/libhmbcodecs.a" | grep -E '/opt/homebrew|/usr/local'; then die "Homebrew path in the string table"; fi

log "creating xcframework"
mkdir -p "$ROOT/Vendor/xcframeworks"
rm -rf "$XCF"
xcodebuild -create-xcframework -library "$WORK/libhmbcodecs.a" -output "$XCF" >/dev/null
[ -f "$LIB_IN_XCF" ] || die "xcframework layout unexpected: $LIB_IN_XCF missing"

copy_headers() { # dest
    local dest="$1" root rel target src_root src
    rm -rf "$dest"
    mkdir -p "$dest"
    while read -r root rel target; do
        case "$root" in ''|'#'*) continue ;; esac
        src_root="$(resolve_root "$root")"
        src="$src_root/$rel"
        [ -f "$src" ] || die "missing header $src"
        mkdir -p "$(dirname "$dest/$target")"
        cp "$src" "$dest/$target"
    done < "$ROOT/Scripts/codec-headers.txt"
    if grep -rE '/opt/homebrew|/usr/local' "$dest"; then die "Homebrew path in a copied header"; fi
    printf 'libjxl %s %s\nlibwebp %s %s\n' "$LIBJXL_TAG" "$LIBJXL_COMMIT" "$LIBWEBP_TAG" "$LIBWEBP_COMMIT" > "$dest/.complete"
}
log "copying headers"
copy_headers "$INCLUDE_OUT"

write_lock_sha() {
    local sha; sha="$(current_sha)"
    if [ "$sha" != "${OUTPUT_SHA256:-}" ]; then
        local tmp="$LOCK.tmp"
        sed -e "s/^OUTPUT_SHA256=.*/OUTPUT_SHA256=\"$sha\"/" "$LOCK" > "$tmp"
        mv "$tmp" "$LOCK"
        if [ -n "${OUTPUT_SHA256:-}" ]; then
            log "note: output differs from the lock (toolchain change?); lock updated to $sha"
        fi
    fi
    log "done: $LIB_IN_XCF ($sha)"
}
write_lock_sha
