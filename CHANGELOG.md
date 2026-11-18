# Changelog

## 1.1 - 2026-11-18

- Fixed: every video failed with "Could not read" on Windows PowerShell 5.1
  (the PowerShell built into Windows 10 and 11). ffmpeg's normal file
  information was being treated as an error.
- AV1 video now works (common for YouTube downloads at 1080p and above):
  ffmpeg.exe now includes the dav1d decoder.
- HDR phone videos (iPhone HLG / Dolby Vision, Samsung HDR10+) are
  tone-mapped to normal colours instead of coming out grey and washed out.
- More formats: DTS and TrueHD audio (MKV films), Theora (OGV), DNxHD and
  MXF (camera / editing files), VOB / MOD / TOD (DVD and camcorder files),
  old camera AVI audio (ADPCM, 8-bit PCM), Flash FLV, WMA Pro.
- Cover-art images inside MP4 files are no longer mistaken for the video.
- The "or click to choose files" hint in the blue box is visible again.
- Much faster: uses the graphics chip's video encoder (NVIDIA NVENC, Intel
  Quick Sync, AMD AMF) when one works on the PC, typically 3-4 times faster
  at the same quality. Without one, the processor now encodes in one pass
  instead of two (about 1.5 times faster). "Best quality" keeps two passes.
- Cancel and continue: the bar no longer shows full after Cancel, the
  message says how many finished parts were kept and where the next run
  continues, and the time-left estimate no longer counts reused parts.
- Finished parts are reused only if they were made with the same settings;
  changing mute, size, part length or quality makes them again.
- The window stays responsive while encoding: restoring it from the taskbar
  after minimising works on the first click (it used to take many tries).
  The title shows the progress (for example "37% - VideoMail"), so it is
  visible on the taskbar while minimised.
- The taskbar shows VideoMail's own icon instead of the PowerShell icon.
- Releases are built by GitHub Actions in a pinned container and are
  reproducible: anyone can rebuild a tag and get a byte-identical zip, or
  check a download with "gh attestation verify" (README: Verify a download).

## 1.0 - 2026-11-18

First release.

- Portable Windows app: no installer, no admin rights, runs from any folder
  or USB stick.
- Drag videos in, press one button: numbered 5-minute MP4 parts, each under
  the configured size cap (49 MB by default).
- Outlook drafts created automatically (classic Outlook); ready-to-forward
  .eml files with new Outlook or no Outlook.
- Automatic downscale (typically 720p), 30 fps cap, optional mute.
- Ships a minimal custom ffmpeg build (~15 MB) with only what the app needs.
- Eight interface languages: English, French, German, Italian, Greek, Arabic,
  Farsi and Hebrew. Follows the Windows language at first start, remembers
  the choice afterwards, and mirrors the interface right-to-left for Arabic,
  Farsi and Hebrew.
