#!/usr/bin/env bash
# Build VideoMail's Windows zip from pinned sources. Runs inside build/Dockerfile:
#
#   docker build -t videomail-build build
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" videomail-build
#
# /src is the repository (read-only); the zip and its .sha256 land in /out.
# An optional /cache volume keeps downloaded sources between runs.
set -euo pipefail
umask 022

SRC_DIR=/src
WORK=/build/work   # fixed path inside the container; part of what makes builds identical
OUT=/out
CACHE=/cache
[ -d "$CACHE" ] && [ -w "$CACHE" ] || CACHE="$WORK.cache"
mkdir -p "$CACHE" "$OUT"

# --- pinned sources ---------------------------------------------------------
# Tarballs: URL + SHA-256. Git sources: URL + full commit hash.
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
FFMPEG_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
DAV1D_URL=https://downloads.videolan.org/pub/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz
DAV1D_SHA=401813f1f89fa8fd4295805aa5284d9aed9bc7fc1fdbe554af4292f64cbabe21
VPL_URL=https://github.com/intel/libvpl/archive/refs/tags/v2.17.0.tar.gz
VPL_SHA=4de3e2faf1e8307fb282e4a43f443191810f6a6b0a484fffa7995ba1c814c6ec
AMF_URL=https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.5.3/AMF-headers-v1.5.3.tar.gz
AMF_SHA=0f521ad98041f8001147cded4a660127f18b1c27a801a5cd691bda1fa48381be
X264_GIT=https://code.videolan.org/videolan/x264.git
X264_COMMIT=0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee
NV_GIT=https://git.videolan.org/git/ffmpeg/nv-codec-headers.git
NV_COMMIT=43d91706e097565f57b311e567f0219838bcc2f6   # tag n11.1.5.3

fetch() {  # url sha256 -> prints the verified local path
    local url=$1 sha=$2 file
    file="$CACHE/$(basename "$url")"
    if [ ! -f "$file" ] || ! echo "$sha  $file" | sha256sum -c --quiet - 2>/dev/null; then
        curl -fsSL --retry 3 -o "$file.tmp" "$url"
        mv "$file.tmp" "$file"
    fi
    if ! echo "$sha  $file" | sha256sum -c --quiet -; then
        echo "Checksum mismatch for $url - refusing to build." >&2
        exit 1
    fi
    printf '%s\n' "$file"
}

gitpin() {  # url commit dir (full clone: x264 derives its version from history)
    local url=$1 commit=$2 dir=$3
    git clone -q "$url" "$dir"
    git -C "$dir" -c advice.detachedHead=false checkout -q "$commit"
    if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
        echo "Could not check out $commit from $url - refusing to build." >&2
        exit 1
    fi
}

# --- workspace --------------------------------------------------------------
mkdir -p "$WORK"
find "$WORK" -mindepth 1 -delete
tar -C "$SRC_DIR" \
    --exclude=./.git --exclude=./.build --exclude=./dist --exclude=./out \
    --exclude=./assets/VideoMail.exe --exclude=./assets/app.res \
    -cf - . | tar -C "$WORK" -xf -

src="$WORK/.build/src"
mkdir -p "$src/amf"
tar -C "$src" -xJf "$(fetch "$FFMPEG_URL" "$FFMPEG_SHA")"
tar -C "$src" -xJf "$(fetch "$DAV1D_URL" "$DAV1D_SHA")"
tar -C "$src" -xzf "$(fetch "$VPL_URL" "$VPL_SHA")"
tar -C "$src/amf" -xzf "$(fetch "$AMF_URL" "$AMF_SHA")"
gitpin "$X264_GIT" "$X264_COMMIT" "$src/x264"
gitpin "$NV_GIT" "$NV_COMMIT" "$src/nv-codec-headers"

# --- build ------------------------------------------------------------------
cd "$WORK"
TC=/usr bash build/build-windows.sh
bash build/package.sh

cp dist/VideoMail-*-win64.zip dist/VideoMail-*-win64.zip.sha256 "$OUT/"
echo
cat "$OUT"/VideoMail-*-win64.zip.sha256
