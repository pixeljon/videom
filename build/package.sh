#!/usr/bin/env bash
# Build the distributable VideoMail folder and zip.
# Requires: pwsh (for the self-test), zip, and the mingw toolchain used by
# build-windows.sh. ffmpeg.exe must already be in .build/out/bin.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

TC="${TC:-$root/.build/tc/usr/bin}"
export PATH="$TC:$PATH"

version="1.1"
dist="$root/dist"
app="$dist/VideoMail"
stamp="202611180000"

echo "== assemble VideoMail.ps1 =="
# The BOM makes Windows PowerShell 5.1 read the file as UTF-8; without it the
# non-English strings would be mangled by the system code page.
printf '\xEF\xBB\xBF' > VideoMail.ps1
cat src/01-core.ps1 src/02-strings.ps1 src/03-encode.ps1 src/04-gui.ps1 src/05-main.ps1 >> VideoMail.ps1

if command -v pwsh >/dev/null 2>&1; then
    echo "== self-test =="
    pwsh -NoProfile -File ./VideoMail.ps1 -SelfTest
fi

echo "== launcher =="
( cd assets
  x86_64-w64-mingw32-windres app.rc -O coff -o app.res
  x86_64-w64-mingw32-gcc -O2 -mwindows -static launcher.c app.res \
      -o VideoMail.exe -lshell32 -s -Wl,--no-insert-timestamp
)

echo "== stage =="
rm -rf "$app"
mkdir -p "$app/source"
cp .build/out/bin/ffmpeg.exe "$app/"
cp .build/out/bin/libwinpthread-1.dll "$app/"
cp assets/VideoMail.exe "$app/"

# Strip build-machine traces from the binaries: zero the PE timestamps
# (header, export and import tables) and recompute the PE checksums.
python3 - "$app/ffmpeg.exe" "$app/libwinpthread-1.dll" "$app/VideoMail.exe" <<'EOF'
import struct, sys

def compute_checksum(d):
    orig_len = len(d)
    data = bytes(d)
    if len(data) % 2:
        data += b'\x00'
    s = 0
    for i in range(0, len(data), 2):
        s += data[i] | (data[i + 1] << 8)
        s = (s + (s >> 16)) & 0xFFFF
    s = (s + (s >> 16)) & 0xFFFF
    return (s + orig_len) & 0xFFFFFFFF

def rva_to_offset(secs, rva):
    for va, vsize, raw, rawsz in secs:
        if va <= rva < va + max(vsize, rawsz):
            return raw + (rva - va)
    return None

def patch(path):
    d = bytearray(open(path, 'rb').read())
    pe = struct.unpack_from('<I', d, 0x3C)[0]
    if d[:2] != b'MZ' or d[pe:pe+4] != b'PE\0\0':
        raise SystemExit('not a PE: ' + path)
    coff = pe + 4
    nsec = struct.unpack_from('<H', d, coff + 2)[0]
    opt_size = struct.unpack_from('<H', d, coff + 16)[0]
    opt = coff + 20
    if struct.unpack_from('<H', d, opt)[0] != 0x20B:
        raise SystemExit('not PE32+: ' + path)
    secs = []
    tbl = opt + opt_size
    for i in range(nsec):
        e = tbl + i * 40
        vsize, va, rawsz, raw = struct.unpack_from('<IIII', d, e + 8)
        secs.append((va, vsize, raw, rawsz))
    dirs = opt + 112

    struct.pack_into('<I', d, coff + 4, 0)                # header timestamp
    exp_rva, _ = struct.unpack_from('<II', d, dirs)
    if exp_rva:
        off = rva_to_offset(secs, exp_rva)
        if off is not None:
            struct.pack_into('<I', d, off + 4, 0)         # export timestamp
    imp_rva, _ = struct.unpack_from('<II', d, dirs + 8)
    if imp_rva:
        off = rva_to_offset(secs, imp_rva)
        if off is not None:
            i = 0
            while True:
                e = off + i * 20
                ilt, ts, fc, nm, ft = struct.unpack_from('<IIIII', d, e)
                if not (ilt or ts or fc or nm or ft):
                    break
                struct.pack_into('<I', d, e + 4, 0)       # import timestamp
                i += 1

    ck_off = opt + 64
    struct.pack_into('<I', d, ck_off, 0)
    struct.pack_into('<I', d, ck_off, compute_checksum(d))
    open(path, 'wb').write(d)

for p in sys.argv[1:]:
    patch(p)
EOF
cp VideoMail.ps1 README.txt LICENSES.txt assets/videomail.ico "$app/"
cp .build/src/ffmpeg-*/COPYING.GPLv2 "$app/COPYING.GPLv2.txt"
cp assets/launcher.c assets/app.rc build/build-windows.sh build/package.sh \
   build/Dockerfile build/reproducible-build.sh "$app/source/"
cat > "$app/source/BUILD.txt" <<'EOF'
How these files were built
==========================

ffmpeg.exe
  build-windows.sh in this folder. It builds ffmpeg 9.0.2, x264,
  dav1d 1.5.1 and Intel libvpl 2.17.0 from source with mingw-w64 for
  64-bit Windows, and links everything statically. NVIDIA (nv-codec-headers
  n11.1.5.3) and AMD (AMF headers 1.5.3) support is headers only; the
  graphics driver provides the encoder at run time.
  Sources: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
           https://downloads.videolan.org/pub/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz
           https://github.com/intel/libvpl/archive/refs/tags/v2.17.0.tar.gz
           https://git.videolan.org/git/ffmpeg/nv-codec-headers.git (n11.1.5.3)
           https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.5.3/AMF-headers-v1.5.3.tar.gz

VideoMail.exe
  launcher.c + app.rc, with mingw-w64:
    x86_64-w64-mingw32-windres app.rc -O coff -o app.res
    x86_64-w64-mingw32-gcc -O2 -mwindows -static launcher.c app.res \
        -o VideoMail.exe -lshell32 -s -Wl,--no-insert-timestamp

VideoMail.ps1
  Concatenation of ../src/01-core.ps1, 02-strings.ps1, 03-encode.ps1,
  04-gui.ps1 and 05-main.ps1, prefixed with a UTF-8 BOM. package.sh does
  this and runs the built-in self-test.

package.sh also zeroes the PE timestamps of the shipped binaries and
normalises the zip timestamps, so nothing about the build machine is
recorded in this package.

Reproducible build
  Official releases are built by GitHub Actions inside the pinned
  container in Dockerfile (base image by digest, compiler packages by
  snapshot.debian.org date, every source by SHA-256 or git commit; see
  reproducible-build.sh). Rebuilding the same release tag that way gives
  a byte-identical zip:

    docker build -t videomail-build build
    docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" videomail-build
    sha256sum out/VideoMail-*-win64.zip
EOF

# Batch files need CRLF line endings.
for f in VideoMail.bat Troubleshooting.bat; do
    sed 's/\r$//; s/$/\r/' "$f" > "$app/$f"
done

# Fixed permissions and timestamps: the zip records neither the build
# machine's umask nor its clock.
find "$app" -type d -exec chmod 755 {} +
find "$app" -type f -exec chmod 644 {} +
chmod 755 "$app"/*.exe "$app"/*.dll
TZ=UTC find "$app" -exec touch -t "$stamp" {} +

echo "== zip =="
rm -f "$dist/VideoMail-$version-win64.zip"
( cd "$dist"
  # Sorted entries: filesystem order differs between machines.
  find VideoMail -print | LC_ALL=C sort | TZ=UTC zip -X -9 -@ "VideoMail-$version-win64.zip" >/dev/null
  sha256sum "VideoMail-$version-win64.zip" > "VideoMail-$version-win64.zip.sha256"
)

echo
ls -lh "$app"
du -sh "$app" "$dist/VideoMail-$version-win64.zip"
cat "$dist/VideoMail-$version-win64.zip.sha256"
