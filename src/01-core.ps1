# Generated from src/01-core.ps1 ... src/05-main.ps1 by build/package.sh.
<#
.SYNOPSIS
  VideoMail - split long videos into email-sized parts and create Outlook drafts.

.DESCRIPTION
  Drop one or more videos on the window, press one button, and get:
    - numbered MP4 parts (default 5 minutes, each just under the size cap)
    - one Outlook draft per email, with attachments and body already filled in

  Everything runs locally. Nothing is uploaded.

.PARAMETER Language
  Interface language: auto (default), en, fr, de, it, el, ar, fa or he.
  With auto, the saved choice from Options is used, then the Windows language.

.PARAMETER Cli
  Run without the window (for testing / power users).

.EXAMPLE
  .\VideoMail.ps1 -Cli -InputPath C:\video.mp4 -OutDir C:\out -TargetMB 49 -Minutes 5
#>
param(
    [string[]]$InputPath,
    [string]$OutDir,
    [double]$TargetMB = 49,
    [double]$Minutes = 5,
    [ValidateSet('best', 'balanced', 'fast')]
    [string]$Quality = 'balanced',
    [switch]$Mute,
    [string]$Greeting = '',
    [string]$To = '',
    [switch]$NoDrafts,
    [ValidateSet('auto', 'en', 'fr', 'de', 'it', 'el', 'ar', 'fa', 'he')]
    [string]$Language = 'auto',
    [switch]$Cli,
    [switch]$SelfTest,
    [string]$FfmpegPath,
    # auto: graphics-chip encoder when one works, else the processor.
    # cpu: always the processor (troubleshooting).
    [ValidateSet('auto', 'cpu')]
    [string]$EncoderMode = 'auto'
)

$ErrorActionPreference = 'Stop'

$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:Ffmpeg = if ($FfmpegPath) { $FfmpegPath } else { Join-Path $script:AppDir 'ffmpeg.exe' }
$script:HasGui = $false
$script:CancelRequested = $false
$script:LastPercentShown = -1
$script:LogPath = Join-Path ([IO.Path]::GetTempPath()) 'VideoMail.log'
$script:UiStatus = $null
$script:UiProgress = $null
$script:UiLog = $null
$script:UiForm = $null
$script:UiSummary = $null
$script:CurPartIndex = 0
$script:CurPassStart = 0.0
$script:CurPassLen = 1.0
$script:TotalParts = 1
$script:JobClock = $null
$script:EtaClock = $null
$script:EtaBase = 0.0
$script:ReadingVideos = $false
# Encoder picked earlier in this session, per quality/mode, so the
# graphics-chip check runs once per session rather than once per run.
$script:EncoderCache = @{}

function Write-FileLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-AppLog {
    param([string]$Message)
    Write-FileLog $Message
    if ($script:HasGui -and $script:UiLog) {
        try {
            $script:UiLog.AppendText($Message + "`r`n")
            $script:UiLog.SelectionStart = $script:UiLog.TextLength
            $script:UiLog.ScrollToCaret()
        } catch { }
    }
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds)) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    if ($ts.TotalHours -ge 1) {
        return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
    }
    return ('{0}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Format-Eta {
    param([double]$Seconds)
    if ($Seconds -lt 45) { return (Get-Str 'etaSoon') }
    if ($Seconds -lt 3600) { return ((Get-Str 'etaMinutes') -f [int][math]::Ceiling($Seconds / 60)) }
    return ((Get-Str 'etaHours') -f [int][math]::Floor($Seconds / 3600), [int][math]::Round(($Seconds % 3600) / 60))
}

function Get-SafeTitle {
    param([string]$Name)
    # Decompose accents so "Ferias" survives even though ffmpeg on Windows
    # only handles ASCII command-line paths reliably.
    $t = $Name
    try {
        $t = $t.Normalize([System.Text.NormalizationForm]::FormD)
        $t = $t -replace '\p{Mn}', ''
    } catch { }
    $t = $t -replace '[^\x20-\x7E]', ''
    $t = $t -replace '[\\/:*?"<>|]', ' '
    $t = $t -replace '\s+', '_'
    $t = $t.Trim('_', '.', ' ')
    if (-not $t) { $t = 'video' }
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60).TrimEnd('_') }
    return $t
}

function Format-MB {
    param([double]$Bytes)
    if ($Bytes -ge 1000000000) { return ('{0:0.00} GB' -f ($Bytes / 1000000000.0)) }
    return ('{0:0.0} MB' -f ($Bytes / 1000000.0))
}

function Wait-ProcessResponsive {
    param([System.Diagnostics.Process]$Process, [int]$Milliseconds)
    # Wait up to $Milliseconds for the process to exit (-1: no limit), and
    # keep the window answering the whole time. The window shares this
    # thread, so a long blocking wait makes it ignore clicks: restoring it
    # from the taskbar while minimised then only works by luck. Waiting in
    # short slices and handling window messages between them keeps it
    # responsive within ~15 ms. Returns $true once the process has exited.
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($script:HasGui) {
            if ($Process.WaitForExit(15)) { return $true }
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
        } else {
            if ($Process.WaitForExit(100)) { return $true }
        }
        if ($Milliseconds -ge 0 -and $clock.ElapsedMilliseconds -ge $Milliseconds) { return $false }
    }
}

function Invoke-FFmpegCapture {
    param([string[]]$Arguments, [int]$TimeoutMs = 60000)

    # Run ffmpeg as a plain process and read stderr as text. Calling it with
    # "& ffmpeg ... 2>&1" breaks under Windows PowerShell 5.1: with
    # $ErrorActionPreference = 'Stop', its first stderr line (the normal
    # "Input #0, ..." header) is raised as a terminating error.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-Arg ([string]$_) }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $false
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not (Wait-ProcessResponsive -Process $proc -Milliseconds $TimeoutMs)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; Text = ''; TimedOut = $true }
        }
        $proc.WaitForExit()
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Text = [string]$errTask.Result; TimedOut = $false }
    } finally {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        $proc.Dispose()
    }
}

function Invoke-FFmpegProbe {
    param([string]$VideoPath)
    $r = Invoke-FFmpegCapture -Arguments @('-hide_banner', '-nostdin', '-i', $VideoPath)
    if ($r.TimedOut) { throw ((Get-Str 'errNotVideo') -f (Split-Path -Leaf $VideoPath)) }
    return $r.Text
}

function Get-MediaInfo {
    param([string]$VideoPath)

    if (-not (Test-Path -LiteralPath $VideoPath)) {
        throw ((Get-Str 'errNotFound') -f $VideoPath)
    }

    # ffmpeg prints the stream table when given only -i. Exit code 1 is normal
    # here because no output file was requested.
    $text = Invoke-FFmpegProbe -VideoPath $VideoPath
    $lines = @($text -split "`r?`n")

    $dm = [regex]::Match($text, 'Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)')
    if (-not $dm.Success) {
        throw ((Get-Str 'errNotVideo') -f (Split-Path -Leaf $VideoPath))
    }
    $duration = ([int]$dm.Groups[1].Value * 3600) + ([int]$dm.Groups[2].Value * 60) + [double]$dm.Groups[3].Value

    # Skip cover art / thumbnails, which ffmpeg also lists as video streams.
    $videoLine = @($lines | Where-Object { $_ -match 'Stream #\d+:\d+.*Video:' -and $_ -notmatch '\(attached pic\)' }) | Select-Object -First 1
    if (-not $videoLine) {
        throw ((Get-Str 'errNoVideoTrack') -f (Split-Path -Leaf $VideoPath))
    }

    $dim = [regex]::Match($videoLine, '(\d{2,5})x(\d{2,5})')
    if (-not $dim.Success) {
        throw ((Get-Str 'errNoFrameSize') -f (Split-Path -Leaf $VideoPath))
    }
    $width = [int]$dim.Groups[1].Value
    $height = [int]$dim.Groups[2].Value

    # HDR (PQ / HLG): iPhone records HLG by default, Samsung HDR10+ uses PQ.
    # These need tone mapping, or the SDR result looks grey and washed out.
    $hdr = ($videoLine -match '\b(smpte2084|arib-std-b67)\b')

    $rotation = 0
    $rm = [regex]::Match($text, 'rotation of\s+(-?[\d.]+)\s+degrees')
    if ($rm.Success) { $rotation = [int][math]::Round([double]$rm.Groups[1].Value) }
    if ([math]::Abs($rotation) % 180 -eq 90) {
        $tmp = $width
        $width = $height
        $height = $tmp
    }

    $fps = 30.0
    $fm = [regex]::Match($videoLine, '([\d.]+)\s+fps')
    if ($fm.Success) { $fps = [double]$fm.Groups[1].Value }
    if ($fps -le 0 -or [double]::IsNaN($fps)) { $fps = 30.0 }

    $audioLine = @($lines | Where-Object { $_ -match 'Stream #\d+:\d+.*Audio:' }) | Select-Object -First 1
    $channels = 0
    if ($audioLine) {
        $channels = 2
        if ($audioLine -match '\bmono\b') { $channels = 1 }
        $cm = [regex]::Match($audioLine, '(\d+)\s+channels')
        if ($cm.Success) { $channels = [int]$cm.Groups[1].Value }
    }

    $size = (Get-Item -LiteralPath $VideoPath).Length

    return [pscustomobject]@{
        Path     = (Resolve-Path -LiteralPath $VideoPath).Path
        Duration = $duration
        Width    = $width
        Height   = $height
        Rotation = $rotation
        Fps      = $fps
        Channels = $channels
        Hdr      = [bool]$hdr
        Size     = $size
    }
}

function Get-EncodePlan {
    param(
        [double]$DurationSec,
        [double]$TargetMB,
        [int]$AudioKbps,
        [bool]$Mute,
        [int]$Width,
        [int]$Height,
        [double]$Fps,
        [bool]$Hdr = $false
    )

    if ($DurationSec -le 0) { throw 'Internal error: zero-length part.' }

    # Decimal MB: 49 MB = 49,000,000 bytes, safely under a 50 MB mail limit.
    $targetBytes = $TargetMB * 1000000.0
    $totalKbps = ($targetBytes * 8.0 / 1000.0) / $DurationSec

    # 2% headroom for container overhead and ABR variation.
    $videoKbps = [int][math]::Floor($totalKbps * 0.98) - $(if ($Mute) { 0 } else { $AudioKbps })
    if ($videoKbps -lt 100) {
        throw ((Get-Str 'errTooSmall') -f $TargetMB, [math]::Round($DurationSec / 60, 1))
    }

    # More pixels than the bitrate can support looks worse than a clean,
    # smaller frame. Pick a sensible cap for the budget.
    $capPixels = 230400
    if ($videoKbps -ge 700) { $capPixels = 921600 }
    elseif ($videoKbps -ge 400) { $capPixels = 518400 }

    $filters = @()
    if ($Fps -gt 31) { $filters += 'fps=30' }

    # ffmpeg's scaler tone-maps HDR to SDR (perceptual intent) when asked
    # for BT.709 output, so HDR needs no extra filter library.
    $toSdr = ''
    if ($Hdr) { $toSdr = ':out_primaries=bt709:out_transfer=bt709:out_color_matrix=bt709:out_range=tv' }

    $pixels = [double]$Width * [double]$Height
    if ($pixels -gt $capPixels) {
        $factor = [math]::Sqrt($capPixels / $pixels)
        $newW = [int]([math]::Floor(($Width * $factor) / 2.0) * 2)
        $newH = [int]([math]::Floor(($Height * $factor) / 2.0) * 2)
        if ($newW -lt 2) { $newW = 2 }
        if ($newH -lt 2) { $newH = 2 }
        $filters += "scale=${newW}:${newH}:flags=lanczos$toSdr"
    } elseif (($Width % 2) -ne 0 -or ($Height % 2) -ne 0) {
        $filters += "scale=trunc(iw/2)*2:trunc(ih/2)*2$toSdr"
    } elseif ($Hdr) {
        $filters += "scale=iw:ih$toSdr"
    }
    $filters += 'format=yuv420p'

    # Tag the output as SDR BT.709 after tone mapping, so players do not
    # treat it as HDR.
    $colorArgs = @()
    if ($Hdr) { $colorArgs = @('-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709') }

    return [pscustomobject]@{
        TargetBytes = $targetBytes
        VideoKbps   = $videoKbps
        AudioKbps   = $(if ($Mute) { 0 } else { $AudioKbps })
        VideoFilter = ($filters -join ',')
        ColorArgs   = $colorArgs
    }
}

function Test-TargetFit {
    param([double]$DurationSec, [double]$TargetMB, [int]$AudioKbps, [bool]$Mute)
    $plan = Get-EncodePlan -DurationSec $DurationSec -TargetMB $TargetMB -AudioKbps $AudioKbps -Mute $Mute -Width 1280 -Height 720 -Fps 30
    $estimate = (($plan.VideoKbps + $plan.AudioKbps) * 1000.0 / 8.0) * $DurationSec
    return [pscustomobject]@{ Plan = $plan; EstimateBytes = $estimate; Fits = ($estimate -le ($TargetMB * 1000000.0)) }
}
