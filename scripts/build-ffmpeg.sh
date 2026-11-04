#!/usr/bin/env bash
# Builds the remux-only LGPL ffmpeg helper as a universal binary (docs/adr/0008).
#
# Usage: build-ffmpeg.sh [output path]. The default is build/ffmpeg/ffmpeg.
# A finished helper whose build stamp matches this script is reused.
set -euo pipefail
source "$(dirname "$0")/common.sh"

FFMPEG_VERSION="8.1.3"
FFMPEG_SHA256="7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

OUTPUT="${1:-$BUILD_DIR/ffmpeg/ffmpeg}"
WORK="$BUILD_DIR/ffmpeg-work"
STAMP="$OUTPUT.stamp"
SCRIPT_HASH="$(shasum -a 256 "$0" | awk '{print $1}')"

grep -q "ffmpeg-$FFMPEG_VERSION.tar.xz" "$ROOT/App/Credits.html" || die "App/Credits.html must name the source of FFmpeg $FFMPEG_VERSION"

if [ -x "$OUTPUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SCRIPT_HASH" ]; then
  log "ffmpeg $FFMPEG_VERSION is already built at $OUTPUT"
  exit 0
fi

mkdir -p "$WORK" "$(dirname "$OUTPUT")"
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  log "Downloading FFmpeg $FFMPEG_VERSION"
  curl --fail --location --silent --show-error --proto '=https' --output "$TARBALL.download" "$FFMPEG_URL"
  mv "$TARBALL.download" "$TARBALL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL" != "$FFMPEG_SHA256" ]; then
  rm -f "$TARBALL"
  die "FFmpeg tarball hash $ACTUAL doesn't match the pinned $FFMPEG_SHA256"
fi

SOURCE="$WORK/ffmpeg-$FFMPEG_VERSION"
rm -rf "$SOURCE"
tar -xJf "$TARBALL" -C "$WORK"

CONFIGURE_FLAGS=(
  --disable-gpl
  --disable-nonfree
  --disable-version3
  --disable-autodetect
  --disable-everything
  --disable-doc
  --disable-ffplay
  --disable-ffprobe
  --disable-network
  --disable-asm
  --disable-debug
  --disable-shared
  --enable-static
  --disable-avdevice
  --disable-swscale
  --disable-swresample
  --enable-small
  --enable-protocol=file,pipe
  --enable-demuxers
  --enable-muxers
  --enable-parsers
  --enable-bsfs
  --enable-encoder=movtext,srt,subrip,webvtt
  --enable-decoder=movtext,srt,subrip,webvtt
  --pkg-config-flags=--static
)

build_arch() {
  local arch="$1"
  local folder="$WORK/build-$arch"
  rm -rf "$folder"
  mkdir -p "$folder"
  log "Configuring ffmpeg for $arch"
  (cd "$folder" && "$SOURCE/configure" \
    "${CONFIGURE_FLAGS[@]}" \
    --arch="$arch" \
    --target-os=darwin \
    --enable-cross-compile \
    --cc="clang -arch $arch" \
    --extra-cflags="-mmacosx-version-min=14.0" \
    --extra-ldflags="-mmacosx-version-min=14.0" \
    >"$folder/configure.log" 2>&1) || { tail -40 "$folder/configure.log"; die "configure failed for $arch"; }
  log "Building ffmpeg for $arch"
  make -C "$folder" -j"$(sysctl -n hw.ncpu)" ffmpeg >"$folder/make.log" 2>&1 || { tail -40 "$folder/make.log"; die "make failed for $arch"; }
}

build_arch arm64
build_arch x86_64

lipo -create "$WORK/build-arm64/ffmpeg" "$WORK/build-x86_64/ffmpeg" -output "$OUTPUT.new"
chmod 755 "$OUTPUT.new"
codesign --force --sign - "$OUTPUT.new"

log "Checking the helper can only remux"
check_config() {
  local header="$1"
  local pattern="$2"
  if grep -E "$pattern" "$header" | grep -E ' 1$' >/dev/null; then
    grep -E "$pattern" "$header" | grep -E ' 1$' | head -20
    die "the ffmpeg build enables something it must not: $pattern"
  fi
}
for arch in arm64 x86_64; do
  config="$WORK/build-$arch/config.h"
  components="$WORK/build-$arch/config_components.h"
  [ -s "$config" ] && [ -s "$components" ] || die "configure left no config headers for $arch"
  grep -q '^#define CONFIG_MOVTEXT_ENCODER 1$' "$components" || die "the codec check can't read $components"
  check_config "$config" '^#define CONFIG_(GPL|NONFREE|VERSION3) '
  allowed='^#define CONFIG_(MOVTEXT|SRT|SUBRIP|WEBVTT)_(EN|DE)CODER '
  enabled_codecs="$(grep -E '^#define CONFIG_[A-Z0-9_]+_(EN|DE)CODER 1$' "$components" | grep -Ev "$allowed" || true)"
  if [ -n "$enabled_codecs" ]; then
    echo "$enabled_codecs" | head -20
    die "the ffmpeg build enables an audio or video encoder or decoder"
  fi
done
"$OUTPUT.new" -hide_banner -L | grep -q "GNU Lesser General Public" || die "the helper doesn't report the LGPL"

mv "$OUTPUT.new" "$OUTPUT"
echo "$SCRIPT_HASH" > "$STAMP"
lipo -archs "$OUTPUT" | sed 's/^/architectures: /'
log "Built ffmpeg $FFMPEG_VERSION at $OUTPUT"
