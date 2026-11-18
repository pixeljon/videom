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
    [string]$FfmpegPath
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

function Get-MediaInfo {
    param([string]$VideoPath)

    if (-not (Test-Path -LiteralPath $VideoPath)) {
        throw ((Get-Str 'errNotFound') -f $VideoPath)
    }

    # ffmpeg prints the stream table when given only -i. Exit code 1 is normal
    # here because no output file was requested.
    $lines = @(& $script:Ffmpeg -hide_banner -i $VideoPath 2>&1 | ForEach-Object { [string]$_ })
    $text = $lines -join "`n"

    $dm = [regex]::Match($text, 'Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)')
    if (-not $dm.Success) {
        throw ((Get-Str 'errNotVideo') -f (Split-Path -Leaf $VideoPath))
    }
    $duration = ([int]$dm.Groups[1].Value * 3600) + ([int]$dm.Groups[2].Value * 60) + [double]$dm.Groups[3].Value

    $videoLine = @($lines | Where-Object { $_ -match 'Stream #\d+:\d+.*Video:' }) | Select-Object -First 1
    if (-not $videoLine) {
        throw ((Get-Str 'errNoVideoTrack') -f (Split-Path -Leaf $VideoPath))
    }

    $dim = [regex]::Match($videoLine, '(\d{2,5})x(\d{2,5})')
    if (-not $dim.Success) {
        throw ((Get-Str 'errNoFrameSize') -f (Split-Path -Leaf $VideoPath))
    }
    $width = [int]$dim.Groups[1].Value
    $height = [int]$dim.Groups[2].Value

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
        [double]$Fps
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

    $pixels = [double]$Width * [double]$Height
    if ($pixels -gt $capPixels) {
        $factor = [math]::Sqrt($capPixels / $pixels)
        $newW = [int]([math]::Floor(($Width * $factor) / 2.0) * 2)
        $newH = [int]([math]::Floor(($Height * $factor) / 2.0) * 2)
        if ($newW -lt 2) { $newW = 2 }
        if ($newH -lt 2) { $newH = 2 }
        $filters += "scale=${newW}:${newH}:flags=lanczos"
    } elseif (($Width % 2) -ne 0 -or ($Height % 2) -ne 0) {
        $filters += 'scale=trunc(iw/2)*2:trunc(ih/2)*2'
    }
    $filters += 'format=yuv420p'

    return [pscustomobject]@{
        TargetBytes = $targetBytes
        VideoKbps   = $videoKbps
        AudioKbps   = $(if ($Mute) { 0 } else { $AudioKbps })
        VideoFilter = ($filters -join ',')
    }
}

function Test-TargetFit {
    param([double]$DurationSec, [double]$TargetMB, [int]$AudioKbps, [bool]$Mute)
    $plan = Get-EncodePlan -DurationSec $DurationSec -TargetMB $TargetMB -AudioKbps $AudioKbps -Mute $Mute -Width 1280 -Height 720 -Fps 30
    $estimate = (($plan.VideoKbps + $plan.AudioKbps) * 1000.0 / 8.0) * $DurationSec
    return [pscustomobject]@{ Plan = $plan; EstimateBytes = $estimate; Fits = ($estimate -le ($TargetMB * 1000000.0)) }
}
