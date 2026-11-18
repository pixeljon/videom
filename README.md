# VideoMail

**Long videos in. Email-sized parts and ready-to-send Outlook drafts out.**

VideoMail is a small portable Windows app for sending a long video by email.
Drop a video on the window, press one button, and it produces numbered
5-minute MP4 parts that fit under your mail size limit — plus Outlook drafts
with the parts already attached and the message already written.

No installer. No admin rights. No upload. Everything runs on the PC.

![VideoMail main window](docs/screenshot-main.png)

## Why

Mail providers usually stop at 25–50 MB. A one-hour phone video is several
gigabytes. VideoMail does the boring part: cut, re-encode, name, number,
check the size, and prepare the emails.

## Features

- **One button.** Drag videos (or a folder) onto the window, press
  **Split & prepare emails**.
- **Eight languages.** English, Français, Deutsch, Italiano, Ελληνικά,
  العربية, فارسی and עברית. The app opens in the language Windows uses,
  and once you pick a language in Options it stays chosen. Arabic, Farsi
  and Hebrew get a fully right-to-left window.
- **Fits the limit.** Every part is encoded to stay under the configured
  size (49 MB by default, decimal megabytes).
- **Numbered parts.** `Fishing_trip_part01_of_12.mp4`, zero-padded so the
  order is obvious on disk and in the mail.
- **Outlook drafts.** One draft per email, with greeting, part list and
  attachments. Open Outlook and press Send.
- **Works without Outlook.** No classic Outlook, or "new Outlook"? It writes
  ready-to-forward `.eml` files instead.
- **Mute option.** Tick *Remove sound (mute)* for silent parts.
- **Portable.** Copy the folder to a USB stick. Nothing is installed and no
  registry entries are written.
- **Readable output.** H.264 + AAC MP4, automatically sized for the bitrate
  budget (usually 720p), plays on phones, TVs and PCs.

## Quick start

1. Download `VideoMail-1.0-win64.zip` from
   [Releases](../../releases/latest).
2. Unzip it anywhere — the desktop, a USB stick, a folder.
3. Double-click **VideoMail.exe**.
4. Drag one or more videos onto the blue box.
5. Press **Split & prepare emails**.
6. Wait. A one-hour video takes roughly 20–60 minutes on a typical laptop.
7. Open **Outlook → Drafts**, check the message, press **Send**.

The parts are saved in a **VideoMail parts** folder next to the original
video. You can change that under **Options**.

![The same window in Arabic](docs/screenshot-arabic-rtl.png)

> Windows may show *"Windows protected your PC"* the first time because the
> app is not code-signed. Click **More info → Run anyway**.

## Languages

English, French, German, Italian, Greek, Arabic, Farsi and Hebrew. The first
start follows the Windows display language; after you choose one in Options
it is remembered (a one-line `VideoMail.settings.txt` next to the program, or
`%APPDATA%\VideoMail` when the folder is read-only). The window, messages,
logs and the email drafts are all translated, and Arabic, Farsi and Hebrew
flip the interface right-to-left. Output file names stay in Latin letters so
they open cleanly everywhere.

## How it works

Each part is encoded independently with two-pass H.264 ABR. The bitrate is
calculated from the size limit and the part length, with 2% headroom for
container overhead. If the budget is too low for the source resolution, the
video is scaled down (typically to 720p at 49 MB / 5 min). A tiny final part
(under 5 seconds) is merged into the previous one.

Audio is AAC at 96 kbps stereo (64 kbps mono). Mute removes the audio track
completely.

## Options

| Setting | Default | Notes |
|---|---|---|
| Language | the Windows language | Eight choices; remembered once you pick one. |
| Maximum size per email | 49 MB | Lower it to 35 MB if your mail server rejects large messages. |
| Part length | 5 minutes | 1–30 minutes. |
| Quality | Balanced | Best quality / Balanced / Fastest. |
| Greeting | `Hello,` | First line of every draft. |
| Send drafts to | empty | Optional; fills the To line. |
| Save parts in | next to the source | Any folder. |
| Create Outlook drafts | on | Untick to only produce the MP4 files. |

![Options window](docs/screenshot-options.png)

Use **35 MB** if sending fails. Mail encoding (Base64) makes a 49 MB file
about 65 MB on the wire, and some providers count that instead of the file
size.

## Outlook

- **Classic Outlook for Windows** is needed for automatic drafts. VideoMail
  uses Outlook's COM interface and saves each message in Drafts; the sender
  account is whatever Outlook is already using.
- **New Outlook, Outlook on the web, or no Outlook:** VideoMail writes
  `.eml` files into `Email drafts - open and forward`. Open one, click
  **Forward**, add the recipient, and send.
- Large attachments also use space in Outlook's local data file.

## Supported input

**Containers:** MP4, MOV, M4V, MKV, WebM, AVI, WMV, ASF, FLV, TS, MTS, M2TS,
MPG, MPEG, 3GP, DV.

**Video:** H.264, HEVC, MPEG-2, MPEG-4, H.263, DV, VP8/VP9, AV1, WMV/VC-1,
ProRes.

**Audio:** AAC, MP3, MP2, AC3/E-AC3, FLAC, Opus, Vorbis, WMA, AMR.

## Build from source

The Windows build is cross-compiled on Linux with mingw-w64.

Requirements: `mingw-w64`, `nasm`, `make`, `pkg-config`, `zip`, and
PowerShell 7 (`pwsh`) for the self-test.

```bash
# Sources (versions used for the release)
mkdir -p .build/src && cd .build/src
curl -LO https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
tar xf ffmpeg-9.0.2.tar.xz
git clone https://code.videolan.org/videolan/x264.git
cd ../..

# Build ffmpeg.exe (minimal, static, with x264)
TC=/usr bash build/build-windows.sh

# Assemble the portable folder and zip
bash build/package.sh
```

`build/build-windows.sh` also works with a custom mingw toolchain in
`.build/tc`; point `TC` at its root. The resulting binary is stripped and
contains no build-machine paths.

`VideoMail.ps1` is generated by concatenating `src/01-core.ps1`,
`src/02-strings.ps1`, `src/03-encode.ps1`, `src/04-gui.ps1` and
`src/05-main.ps1`; `package.sh` does this and runs the built-in self-test.

## Project layout

```
VideoMail.ps1        generated single-file app
src/                 app sources, split by area
assets/              icon, version info, launcher source
build/               Windows build and packaging scripts
docs/                interface previews
README.txt           the readme shipped inside the zip
LICENSES.txt         third-party licenses
```

## Privacy

VideoMail reads the selected videos, writes the parts to the output folder,
and writes a log to `%TEMP%\VideoMail.log`. If you change the language, it
saves that single choice in a small text file next to the program (or in
`%APPDATA%\VideoMail` if the program folder is read-only). It does not use
the network. Nothing is uploaded.

## License

The VideoMail scripts and launcher are MIT licensed; see [LICENSE](LICENSE).
`ffmpeg.exe` is GPLv2+ because it includes x264. See
[LICENSES.txt](LICENSES.txt) and [COPYING.GPLv2.txt](COPYING.GPLv2.txt) for
the bundled components and source locations.

---

*The interface images above are layout previews rendered from the UI code.
Windows may render fonts and controls slightly differently.*
