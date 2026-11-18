#!/usr/bin/env bash
# Cross-build the minimal Windows ffmpeg.exe used by VideoMail.
# Needs: mingw-w64 gcc, nasm, make, pkg-config, and the sources below.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD:-$HERE/../.build}"
TC="${TC:-$BUILD/tc}"
NASM_BIN="${NASM_BIN:-$BUILD/nasm/bin}"
SRC="${SRC:-$BUILD/src}"
OUT="${OUT:-$BUILD/out}"
X264_PREFIX="${X264_PREFIX:-$BUILD/x264}"

if [ -d "$TC/usr/bin" ]; then
  export PATH="$TC/usr/bin:$PATH"
elif [ -d "$TC/bin" ]; then
  export PATH="$TC/bin:$PATH"
fi
if [ -d "$NASM_BIN" ]; then export PATH="$NASM_BIN:$PATH"; fi
export PKG_CONFIG_PATH="$X264_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

X264_SRC="$SRC/x264"
FFMPEG_SRC="$SRC/ffmpeg-9.0.2"

[ -d "$X264_SRC" ] || { echo "Missing x264 source: $X264_SRC" >&2; exit 1; }
[ -d "$FFMPEG_SRC" ] || { echo "Missing ffmpeg source: $FFMPEG_SRC" >&2; exit 1; }

if [ ! -f "$X264_PREFIX/lib/libx264.a" ]; then
  cd "$X264_SRC"
  ./configure \
    --host=x86_64-w64-mingw32 \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-static --enable-strip --disable-cli --disable-opencl \
    --prefix="$X264_PREFIX"
  make -j"$(nproc)"
  make install
fi

mkdir -p "$OUT/obj"
cd "$OUT/obj"

if [ ! -f Makefile ]; then
  "$FFMPEG_SRC/configure" \
    --prefix=/videomail \
    --pkg-config="$(command -v pkg-config)" \
    --arch=x86_64 --target-os=mingw32 \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-cross-compile \
    --enable-gpl --enable-libx264 \
    --disable-everything \
    --disable-doc --disable-debug --disable-network --disable-autodetect \
    --disable-iconv --disable-sdl2 --disable-vaapi --disable-vdpau \
    --disable-vulkan --disable-d3d11va --disable-dxva2 \
    --enable-protocol=file,pipe \
    --enable-demuxer=mov,matroska,avi,mpegts,flv,mpegps,wav,mp3,aac,ogg,asf,dv \
    --enable-decoder=h264,hevc,mpeg4,mpeg2video,mpeg1video,h263,msmpeg4v3,dvvideo,vp8,vp9,vp6f,av1,mjpeg,prores,wmv1,wmv2,wmv3,vc1,alac,aac,mp3,mp2,ac3,eac3,flac,opus,vorbis,wmav1,wmav2,amrnb,amrwb,nellymoser,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le \
    --enable-encoder=libx264,aac \
    --enable-muxer=mp4,null \
    --enable-filter=scale,format,fps,aresample,aformat,setsar,transpose,copy \
    --enable-parser=h264,hevc,mpeg4video,mpegvideo,vp8,vp9,vc1,av1,aac,mpegaudio,ac3,opus,vorbis \
    --enable-bsf=aac_adtstoasc \
    --enable-swscale --enable-swresample
fi

make -j"$(nproc)"
make install DESTDIR="$OUT"

BIN="$OUT/videomail/bin"
x86_64-w64-mingw32-strip "$BIN/ffmpeg.exe"
mkdir -p "$OUT/bin"
cp "$BIN/ffmpeg.exe" "$OUT/bin/ffmpeg.exe"
rm -rf "$OUT/videomail"

DLL=""
for p in "$TC/usr/x86_64-w64-mingw32/bin/libwinpthread-1.dll" \
         "$TC/x86_64-w64-mingw32/bin/libwinpthread-1.dll" \
         "$TC/x86_64-w64-mingw32/lib/libwinpthread-1.dll"; do
  if [ -f "$p" ]; then DLL="$p"; break; fi
done
if [ -z "$DLL" ]; then
  DLL="$(find "$TC" -maxdepth 6 -name libwinpthread-1.dll -path '*x86_64*' 2>/dev/null | head -1)"
fi
[ -n "$DLL" ] || { echo "libwinpthread-1.dll not found under $TC" >&2; exit 1; }
cp "$DLL" "$OUT/bin/libwinpthread-1.dll"

ls -lh "$OUT/bin/ffmpeg.exe" "$OUT/bin/libwinpthread-1.dll"
