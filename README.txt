VideoMail 1.0
=============

WHAT IT DOES
Turn a long video into 5-minute MP4 parts that fit in email, then create
Outlook drafts with the parts attached and the message already written.
You open Outlook and press Send.

Good for fishing trips, matches, school events - anything too long to email.

HOW TO USE
1. Double-click VideoMail.exe. Keep every file in this folder together.
2. Drag one or more videos onto the big blue box.
3. Press "Split & prepare emails".
4. Wait. A 1-hour video usually takes 20-60 minutes; "Fastest" is quicker,
   "Best quality" is slower. Keep the window open and the laptop plugged in.
5. When it says Done, open Outlook -> Drafts. Check each draft, press Send.

The parts are saved in "VideoMail parts" next to the original video.
You can change that folder under Options.

WHAT IS IN THIS FOLDER
VideoMail.exe        double-click this
VideoMail.ps1        the program (keep it next to the exe)
ffmpeg.exe           the video encoder (keep it next to the exe)
libwinpthread-1.dll  runtime piece used by ffmpeg (keep it there)
README.txt           this file
Troubleshooting.bat  only needed if VideoMail.exe will not start
source\              build recipe and license details (not needed to run)

REQUIREMENTS
64-bit Windows 10 or 11. Nothing to install, no admin rights needed.
Classic Outlook (the desktop program) creates the drafts automatically.
Without it, VideoMail saves ready-to-send .eml files instead.

DEFAULTS
- 49 MB per email (under a 50 MB mailbox limit)
- 5 minutes per part
- H.264 + AAC MP4, 720p, plays on phones, TVs and PCs
- Outlook drafts created automatically
- Original sound kept; tick "Remove sound (mute)" for silent parts

LANGUAGES
English, Français, Deutsch, Italiano, Ελληνικά, العربية, فارسی, עברית.
VideoMail opens in the language your Windows uses. Pick another one under
Options and it stays chosen every time you open VideoMail. Arabic, Farsi
and Hebrew show the window right-to-left. The part file names stay in
Latin letters so they work everywhere.

OPTIONS
- Maximum size per email: lower it if Outlook refuses to send.
  Mail systems count the encoded message, which is about a third larger,
  so a 49 MB file can be about 65 MB on the wire. If sending fails,
  choose 35 MB and run again. At 49 MB each email carries one part;
  with smaller sizes, two or more parts can share one email.
- Part length: 5 minutes by default.
- Quality: Best quality / Balanced / Fastest.
- Greeting: the text at the top of every draft ("Hello," by default).
- Send drafts to: optional; fills the To line on every draft.
- Save parts in: where the MP4 files go.
- Create Outlook drafts automatically: untick to only make the files.

FILE NAMES
Fishing_trip_part01_of_12.mp4, _part02_, ... zero-padded, so they sort
correctly in the email and on disk.

OUTLOOK NOTES
- Classic Outlook (the desktop program) is needed for automatic drafts.
- With "new Outlook" or no Outlook, VideoMail saves ready-to-send .eml
  files in "Email drafts - open and forward". Open one, click Forward,
  add the person, and press Send.
- Drafts with large attachments also use space in Outlook's data file.

WHY 720P?
49 MB for 5 minutes is about 1.3 Mbit/s. A clean 720p picture at that
bitrate looks better than a soft, blocky 4K/1080p picture. The app picks
the resolution automatically from the size budget.

IF SOMETHING GOES WRONG
- "Windows protected your PC": click More info -> Run anyway. The app is
  not code-signed.
- Antivirus may scan the first run; allow it.
- If Outlook refuses a message as too large, set 35 MB and run again.
- Log file: %TEMP%\VideoMail.log
- Re-running into the same folder reuses parts that are already complete.
- A very deep folder path (over 260 characters) can fail on older Windows;
  save to something shorter such as C:\VideoMail parts.

SUPPORTED INPUT
MP4, MOV, M4V, MKV, WebM, AVI, WMV, ASF, FLV, TS, MTS, M2TS, MPG, MPEG, 3GP, DV.
Video: H.264, HEVC, MPEG-2, MPEG-4, H.263, DV, VP8/VP9, AV1, WMV/VC-1, ProRes.
Audio: AAC, MP3, MP2, AC3/E-AC3, FLAC, Opus, Vorbis, WMA, AMR.

PRIVACY
Everything happens on this PC. Nothing is uploaded.
If you change the language, VideoMail saves that one choice in a small
file next to the program (or in %APPDATA%\VideoMail if the folder is
read-only).

LICENSE
The VideoMail scripts and launcher are MIT. ffmpeg, x264 and the MinGW
runtime are under their own licenses; see LICENSES.txt.
