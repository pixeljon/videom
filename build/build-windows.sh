#!/usr/bin/env bash
# Cross-build the minimal Windows ffmpeg.exe used by VideoMail.
# Needs: mingw-w64 gcc/g++, nasm, make, pkg-config, meson, cmake + ninja,
# and the sources below (ffmpeg, x264, dav1d, nv-codec-headers, AMF headers,
# libvpl). The GPU encoders (NVIDIA NVENC, AMD AMF, Intel Quick Sync) only
# load the graphics driver at run time; nothing extra ships as a DLL.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD:-$HERE/../.build}"
TC="${TC:-$BUILD/tc}"
NASM_BIN="${NASM_BIN:-$BUILD/nasm/bin}"
SRC="${SRC:-$BUILD/src}"
OUT="${OUT:-$BUILD/out}"
X264_PREFIX="${X264_PREFIX:-$BUILD/x264}"
DAV1D_PREFIX="${DAV1D_PREFIX:-$BUILD/dav1d}"
NV_PREFIX="${NV_PREFIX:-$BUILD/ffnvcodec}"
VPL_PREFIX="${VPL_PREFIX:-$BUILD/vpl}"
MESON="${MESON:-meson}"

if [ -d "$TC/usr/bin" ]; then
  export PATH="$TC/usr/bin:$PATH"
elif [ -d "$TC/bin" ]; then
  export PATH="$TC/bin:$PATH"
fi
if [ -d "$NASM_BIN" ]; then export PATH="$NASM_BIN:$PATH"; fi
export PKG_CONFIG_PATH="$X264_PREFIX/lib/pkgconfig:$DAV1D_PREFIX/lib/pkgconfig:$NV_PREFIX/lib/pkgconfig:$VPL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

X264_SRC="$SRC/x264"
FFMPEG_SRC="$SRC/ffmpeg-9.0.2"
DAV1D_SRC="$SRC/dav1d-1.5.1"
NV_SRC="$SRC/nv-codec-headers"          # git tag n11.1.5.3 (NVIDIA driver 471+)
AMF_INC="$SRC/amf/amf-headers-v1.5.3"   # AMF-headers-v1.5.3.tar.gz
VPL_SRC="$SRC/libvpl-2.17.0"

[ -d "$X264_SRC" ] || { echo "Missing x264 source: $X264_SRC" >&2; exit 1; }
[ -d "$FFMPEG_SRC" ] || { echo "Missing ffmpeg source: $FFMPEG_SRC" >&2; exit 1; }
[ -d "$DAV1D_SRC" ] || { echo "Missing dav1d source: $DAV1D_SRC" >&2; exit 1; }
[ -d "$NV_SRC" ] || { echo "Missing nv-codec-headers: $NV_SRC" >&2; exit 1; }
[ -f "$AMF_INC/AMF/core/Version.h" ] || { echo "Missing AMF headers: $AMF_INC" >&2; exit 1; }
[ -d "$VPL_SRC" ] || { echo "Missing libvpl source: $VPL_SRC" >&2; exit 1; }

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

# dav1d: software AV1 decoder. ffmpeg's own "av1" decoder only drives
# hardware decoding, so without dav1d AV1 files (common for YouTube
# downloads) cannot be decoded.
if [ ! -f "$DAV1D_PREFIX/lib/libdav1d.a" ]; then
  cross="$BUILD/dav1d-cross.ini"
  cat > "$cross" <<'CROSS'
[binaries]
c = 'x86_64-w64-mingw32-gcc'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'
nasm = 'nasm'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
CROSS
  rm -rf "$BUILD/dav1d-build"
  $MESON setup "$BUILD/dav1d-build" "$DAV1D_SRC" --cross-file "$cross" \
    --prefix="$DAV1D_PREFIX" --libdir=lib --buildtype=release \
    --default-library=static \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false
  ninja -C "$BUILD/dav1d-build" install
fi

# NVIDIA: headers only; ffmpeg loads nvEncodeAPI64.dll from the driver.
if [ ! -f "$NV_PREFIX/lib/pkgconfig/ffnvcodec.pc" ]; then
  make -C "$NV_SRC" install PREFIX="$NV_PREFIX"
fi

# AMD: headers only; ffmpeg loads amfrt64.dll from the driver. They go into
# the ffnvcodec include folder, which pkg-config already adds, because ffmpeg
# embeds its configure line in the exe (ffmpeg -version) and an
# --extra-cflags path would record this machine's folders there.
mkdir -p "$NV_PREFIX/include/AMF"
cp -r "$AMF_INC/AMF/." "$NV_PREFIX/include/AMF/"

# Intel Quick Sync: libvpl dispatcher (static); it loads the Intel
# runtime that ships with the graphics driver.
if [ ! -f "$VPL_PREFIX/lib/libvpl.a" ]; then
  tool="$BUILD/mingw-toolchain.cmake"
  {
    echo 'set(CMAKE_SYSTEM_NAME Windows)'
    echo 'set(CMAKE_SYSTEM_PROCESSOR x86_64)'
    echo 'set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)'
    echo 'set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)'
    echo 'set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)'
    echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'
  } > "$tool"
  rm -rf "$BUILD/vpl-build"
  cmake -S "$VPL_SRC" -B "$BUILD/vpl-build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$tool" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$VPL_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
    -DINSTALL_EXAMPLES=OFF -DBUILD_TOOLS=OFF
  ninja -C "$BUILD/vpl-build" install
fi

mkdir -p "$OUT/obj"
cd "$OUT/obj"

# Re-run configure whenever this script changes, so new options apply.
stamp="$(sha256sum "$HERE/build-windows.sh" | cut -d' ' -f1)"
if [ ! -f Makefile ] || [ "$(cat .videomail-config 2>/dev/null)" != "$stamp" ]; then
  "$FFMPEG_SRC/configure" \
    --prefix=/videomail \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-libs="-l:libstdc++.a" \
    --arch=x86_64 --target-os=mingw32 \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-cross-compile \
    --enable-gpl --enable-libx264 --enable-libdav1d \
    --disable-everything \
    --disable-doc --disable-debug --disable-network --disable-autodetect \
    --disable-iconv --disable-sdl2 --disable-vaapi --disable-vdpau \
    --disable-vulkan \
    --enable-d3d11va --enable-dxva2 \
    --enable-ffnvcodec --enable-nvenc --enable-amf --enable-libvpl \
    --enable-protocol=file,pipe \
    --enable-demuxer=mov,matroska,avi,mpegts,flv,mpegps,wav,mp3,aac,ogg,asf,dv,mxf \
    --enable-decoder=libdav1d,h264,hevc,mpeg4,mpeg2video,mpeg1video,h263,msmpeg4v1,msmpeg4v2,msmpeg4v3,flv,dvvideo,vp8,vp9,vp6f,av1,mjpeg,prores,dnxhd,theora,rawvideo,wmv1,wmv2,wmv3,vc1,alac,aac,aac_latm,mp3,mp2,mp1,ac3,eac3,dca,truehd,mlp,flac,opus,vorbis,wmav1,wmav2,wmapro,amrnb,amrwb,nellymoser,adpcm_ima_wav,adpcm_ima_qt,adpcm_ms,adpcm_swf,pcm_u8,pcm_alaw,pcm_mulaw,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le \
    --enable-encoder=libx264,h264_nvenc,h264_amf,h264_qsv,aac \
    --enable-muxer=mp4,null \
    --enable-filter=scale,format,fps,aresample,aformat,setsar,transpose,copy \
    --enable-parser=h264,hevc,mpeg4video,mpegvideo,vp8,vp9,vc1,av1,aac,aac_latm,mpegaudio,ac3,dca,mlp,flac,opus,vorbis,mjpeg,dnxhd,h263 \
    --enable-bsf=aac_adtstoasc \
    --enable-swscale --enable-swresample
  echo "$stamp" > .videomail-config
fi

make -j"$(nproc)"
make install DESTDIR="$OUT"

BIN="$OUT/videomail/bin"
x86_64-w64-mingw32-strip "$BIN/ffmpeg.exe"
# The shipped exe must not record where it was built: no user home folder
# and no path of this build tree. (A bare "/tmp" is normal ffmpeg text.)
leaks="$(grep -aoE '/(home|Users)/[A-Za-z0-9._-]+|/root/' "$BIN/ffmpeg.exe" | sort -u || true)"
build_real="$(cd "$BUILD" && pwd -P)"
if [ -n "$leaks" ] || grep -qaF "$build_real" "$BIN/ffmpeg.exe"; then
  echo "ffmpeg.exe contains a build-machine path; refusing to continue:" >&2
  printf '  %s\n' $leaks "$build_real" >&2
  exit 1
fi
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
  DLL="$(find "$TC" -maxdepth 6 -name libwinpthread-1.dll -path '*x86_64*' 2>/dev/null | head -1 || true)"
fi
[ -n "$DLL" ] || { echo "libwinpthread-1.dll not found under $TC" >&2; exit 1; }
cp "$DLL" "$OUT/bin/libwinpthread-1.dll"

ls -lh "$OUT/bin/ffmpeg.exe" "$OUT/bin/libwinpthread-1.dll"
