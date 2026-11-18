# How VideoMail is built, and how to check it

This page explains what is inside the download, why each piece is there,
how a video becomes email-sized parts, and how anyone can confirm that a
release zip is exactly what this repository's source produces.

## What is in the zip

| File | What it is | Where it comes from |
|---|---|---|
| `VideoMail.ps1` | The whole app: window, encoding logic, Outlook drafts. Readable PowerShell. | Concatenation of `src/01-core.ps1` … `src/05-main.ps1` |
| `VideoMail.exe` | A ~60-line launcher that starts `VideoMail.ps1` with Windows PowerShell and no console window. | `assets/launcher.c`, `assets/app.rc` |
| `ffmpeg.exe` | The video engine: reads the input, decodes, scales, encodes, writes MP4. | ffmpeg 9.0.2 and libraries below, built by `build/build-windows.sh` |
| `libwinpthread-1.dll` | Threading runtime from the MinGW-w64 compiler that ffmpeg uses. | Debian's `mingw-w64` package |
| `videomail.ico` | The app icon (window, taskbar, Alt+Tab), 16–256 px. | `assets/videomail.ico` |
| `VideoMail.bat`, `Troubleshooting.bat` | Alternative launchers, plain text. | Repository root |
| `README.txt`, `LICENSES.txt`, `COPYING.GPLv2.txt` | Help and licenses. | Repository root, ffmpeg source |
| `source\` | The build recipe that produced the binaries. | `build/`, `assets/` |

`ffmpeg.exe`, `VideoMail.exe` and the DLL are the only programs. Everything
else is text or an image.

## The ffmpeg build

VideoMail does not use a general-purpose ffmpeg download. It builds a
minimal one with `--disable-everything` and then enables only what the app
needs, which keeps it at about 19 MB and avoids shipping unused code.

### Libraries linked in

| Library | Version | Why | License |
|---|---|---|---|
| ffmpeg | 9.0.2 | Demuxing, decoding, scaling, HDR tone mapping, AAC encoding, MP4 muxing. | GPL v2+ (because of x264) |
| x264 | commit `0480cb05` | H.264 encoding on the processor; used when no graphics chip encoder works, and always for "Best quality". | GPL v2 |
| dav1d | 1.5.1 | AV1 decoding. ffmpeg's own AV1 decoder only drives hardware decoding, so without dav1d many YouTube downloads (AV1 at 1080p and above) could not be read. | BSD 2-Clause |
| Intel libvpl | 2.17.0 | Dispatcher for Intel Quick Sync encoding. It loads the Quick Sync runtime that ships with the Intel graphics driver. | MIT |
| nv-codec-headers | n11.1.5.3 | Headers only, for NVIDIA NVENC. ffmpeg loads `nvEncodeAPI64.dll` from the NVIDIA driver at run time (driver 471.41 or newer). | MIT |
| AMD AMF headers | 1.5.3 | Headers only, for AMD AMF. ffmpeg loads `amfrt64.dll` from the AMD driver at run time. | MIT |

No graphics-vendor code ships in the zip: the NVIDIA, Intel and AMD encoders
come from the driver already installed on the PC. A PC without one of these
simply uses x264.

### What is enabled

- **Inputs (demuxers):** MP4/MOV/M4V/3GP, MKV/WebM, AVI, MPEG-TS (TS, MTS,
  M2TS), MPEG-PS (MPG, VOB, MOD, TOD), FLV, ASF/WMV, DV, Ogg, MXF, and WAV,
  MP3, AAC.
- **Video decoders:** H.264, HEVC, AV1 (dav1d), VP8, VP9, MPEG-1/2/4,
  H.263, MS-MPEG4, Sorenson FLV, VP6, DV, MJPEG, ProRes, DNxHD, Theora,
  WMV1/2/3, VC-1, raw video.
- **Audio decoders:** AAC (including LATM), MP1/2/3, AC-3, E-AC-3, DTS,
  TrueHD/MLP, FLAC, ALAC, Opus, Vorbis, WMA 1/2/Pro, AMR-NB/WB, Nellymoser,
  ADPCM (IMA WAV, IMA QT, MS, SWF), PCM (8/16/24/32-bit, float, A-law, µ-law).
- **Encoders:** `libx264`, `h264_nvenc`, `h264_qsv`, `h264_amf`, `aac`.
- **Filters:** `scale`, `format`, `fps`, `transpose` (phone rotation),
  `aresample`, `aformat`, `setsar`, `copy`.
- **Output:** MP4 only (plus `null` for analysis passes). No network
  protocols: ffmpeg can only read and write local files.

The exact configure line is in `build/build-windows.sh` and is printed by
`ffmpeg.exe -version`.

## How a video becomes parts

1. **Read.** `ffmpeg -i` prints the stream table. VideoMail reads the
   duration, the first real video stream (cover art is skipped), size,
   rotation, frame rate, audio channels, and whether the video is HDR
   (PQ or HLG transfer).
2. **Plan.** For each part (5 minutes by default) the bitrate is the size
   limit divided by the part length, minus 2% headroom and the audio
   (AAC 96 kbps stereo or 64 kbps mono; none when muted). The frame is
   scaled to what that bitrate can carry (typically 720p at 49 MB / 5 min),
   and anything above 31 fps is reduced to 30 fps. A final part shorter than
   5 seconds is merged into the previous one.
3. **HDR.** iPhone (HLG / Dolby Vision 8.4) and Samsung HDR10+ videos are
   tone-mapped to standard BT.709 colours by ffmpeg's scaler, in the same
   step as resizing, and the output is tagged BT.709. Without this, HDR
   video looks grey and washed out on most screens.
4. **Pick an encoder** (once per session). For *Balanced* and *Fastest*,
   VideoMail encodes one second of the real video with NVIDIA NVENC, then
   Intel Quick Sync, then AMD AMF, and uses the first one that succeeds.
   If none works, it uses x264 in one pass. *Best quality* always uses
   two-pass x264. The log shows the choice ("Encoder: graphics chip (…)" or
   "Encoder: processor (…)").
5. **Encode.** One pass with a peak-rate cap (graphics chip or x264), or two
   passes (x264 "Best quality"). Each part is written as `name.mp4.part` and
   renamed only when complete. If a part comes out over the limit, it is
   encoded again at a proportionally lower bitrate (up to three tries). If
   the graphics chip fails during a run, the rest of the job continues on
   the processor.
6. **Resume.** Each finished part is recorded in a hidden
   `.videomail-parts.txt` in the output folder, as file name plus a SHA-256
   fingerprint of everything that decides its content (source file, size and
   date, part start and length, size limit, audio, filters, quality). A later
   run into the same folder reuses a part only when the fingerprint matches;
   change mute, size, part length or quality and it is made again. Only the
   hash is stored, never the source path.
7. **Drafts.** Parts are grouped so each email stays under the limit, then
   saved as Outlook drafts (classic Outlook, via COM) or as `.eml` files.

Measured on a 60-second 1080p clip encoded to 720p at the 49 MB / 5 min
budget (SSIM against the source, higher is better):

| Encoder | Time | SSIM |
|---|---|---|
| x264 *fast*, two passes (the 1.0 behaviour), 4 cores | 16–19 s | 0.9894 |
| x264 *fast*, one pass, 4 cores | 13–15 s | 0.9905 |
| Intel graphics, hardware encoder (VAAPI), 4 cores | 4.4 s | 0.9893 |
| Intel Quick Sync with VideoMail's settings, all cores | 5.5 s | 0.9890 |

The graphics chip is typically 3–4 times faster than the two-pass encode at
the same quality. The test clip is synthetic, so treat the quality numbers
as a guide.

## Reproducible releases

Official zips are built by GitHub Actions (`.github/workflows/release.yml`)
from a version tag, inside a pinned container, never on a personal computer.

What is pinned:

- **Build environment** (`build/Dockerfile`): Debian 13 (trixie) base image
  by digest, and every package (mingw-w64 GCC 14, NASM 2.16.03, Meson 1.7,
  CMake 3.31, …) from snapshot.debian.org at a fixed date.
- **Sources** (`build/reproducible-build.sh`): every tarball by SHA-256,
  every git source by full commit hash. A mismatch stops the build.
- **Output:** PE timestamps are zeroed and checksums recomputed; zip entries
  are sorted, with fixed permissions and a fixed date (2026-11-18 00:00 UTC);
  `SOURCE_DATE_EPOCH` is set. The build fails if `ffmpeg.exe` contains a
  home-folder path or the build folder's path.

Two independent builds of the same commit in this container produce a
byte-identical zip.

### Privacy of the binaries

Nothing in the zip identifies the machine or person that built it: no user
names, home folders, host names or build paths, no build timestamps, and
no compiler-embedded dates. The release workflow runs on GitHub's servers.

## Verify a download

Quickest first:

1. **Checksum.** Compare the zip's SHA-256 with the one on the release page.
   On Windows: `Get-FileHash .\VideoMail-1.1-win64.zip` in PowerShell.
2. **Build provenance.** With the GitHub CLI:

   ```bash
   gh attestation verify VideoMail-1.1-win64.zip --repo pixeljon/videom
   ```

   This checks a signature that GitHub Actions created when it built the
   file, and shows the workflow and commit it came from.
3. **Rebuild it yourself** (Docker, about 10 minutes):

   ```bash
   git clone https://github.com/pixeljon/videom.git && cd videom
   git checkout v1.1
   docker build -t videomail-build build
   docker run --rm --user "$(id -u):$(id -g)" \
     -v "$PWD:/src:ro" -v "$PWD/out:/out" videomail-build
   sha256sum out/VideoMail-1.1-win64.zip
   ```

   The hash must equal the release's.

## Making a release

1. Update the version in `build/package.sh` and `assets/app.rc`, and add a
   section for it to `CHANGELOG.md`.
2. Commit, then push a tag `v<version>` (for example `v1.1`).
3. The release workflow checks that the tag matches `package.sh`, builds in
   the container, runs the self-test on the packaged app, signs the build
   provenance, and publishes the release with this version's changelog
   section and the SHA-256.

The test workflow (`.github/workflows/test.yml`) runs on every push: it
checks that `VideoMail.ps1` matches its sources and runs the self-test.
