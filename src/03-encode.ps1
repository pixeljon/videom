
function Format-Seconds {
    param([double]$Seconds)
    return $Seconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Get-NullDevice {
    if ($env:OS -eq 'Windows_NT') { return 'NUL' }
    return '/dev/null'
}

function Read-FFmpegProgress {
    param([string]$Path)
    $result = [pscustomobject]@{ Seconds = 0.0; Speed = 0.0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    } catch { return $result }
    if (-not $text) { return $result }

    $m = [regex]::Match($text, 'out_time_us=(\d+)')
    if (-not $m.Success) { $m = [regex]::Match($text, 'out_time_ms=(\d+)') }
    if ($m.Success) { $result.Seconds = [double]$m.Groups[1].Value / 1000000.0 }

    $s = [regex]::Match($text, 'speed=\s*([0-9.]+)x')
    if ($s.Success) { $result.Speed = [double]$s.Groups[1].Value }
    return $result
}

function Invoke-FFmpeg {
    param(
        [string[]]$Arguments,
        [string]$ProgressFile,
        [double]$ExpectedSeconds,
        [scriptblock]$OnTick
    )

    if (Test-Path -LiteralPath $ProgressFile) {
        Remove-Item -LiteralPath $ProgressFile -Force -ErrorAction SilentlyContinue
    }

    $argLine = ($Arguments | ForEach-Object { ConvertTo-Arg ([string]$_) }) -join ' '
    Write-FileLog ('ffmpeg ' + $argLine)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffmpeg
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $false
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while (-not $proc.HasExited) {
            # Progress four times a second; the window stays responsive
            # in between (see Wait-ProcessResponsive).
            [void](Wait-ProcessResponsive -Process $proc -Milliseconds 250)
            if ($script:CancelRequested) {
                try { $proc.Kill() } catch { }
                throw 'Cancelled'
            }
            $prog = Read-FFmpegProgress -Path $ProgressFile
            $frac = 0.0
            if ($ExpectedSeconds -gt 0) {
                $frac = [math]::Min(1.0, $prog.Seconds / $ExpectedSeconds)
            }
            if ($OnTick) { & $OnTick $frac $prog.Speed $clock.Elapsed.TotalSeconds }
        }
        $proc.WaitForExit()
        $err = ''
        try { $err = $errTask.Result } catch { }
        if ($proc.ExitCode -ne 0) {
            if ($script:CancelRequested) { throw 'Cancelled' }
            $tail = ($err -split "`n" | Select-Object -Last 6) -join ' '
            throw ((Get-Str 'errEncoder') -f $tail)
        }
        if ($OnTick) { & $OnTick 1.0 0.0 $clock.Elapsed.TotalSeconds }
    } finally {
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch { }
        }
        try { $proc.Dispose() } catch { }
    }
}

function Get-QualityPreset {
    param([string]$Quality)
    switch ($Quality) {
        'best' { return 'medium' }
        'balanced' { return 'fast' }
        'fast' { return 'veryfast' }
        default { return 'medium' }
    }
}

function New-PartJobs {
    param(
        [pscustomobject]$Media,
        [string]$OutDir,
        [double]$TargetMB,
        [double]$SegmentMinutes,
        [bool]$Mute,
        [hashtable]$UsedNames
    )

    $segmentSeconds = $SegmentMinutes * 60.0
    if ($segmentSeconds -lt 5) { throw (Get-Str 'errShortPart') }

    $count = [int][math]::Ceiling($Media.Duration / $segmentSeconds)
    if ($count -lt 1) { $count = 1 }

    # Avoid a silly 2-second final part (merge it into the previous part).
    $lastLength = $Media.Duration - (($count - 1) * $segmentSeconds)
    if ($count -gt 1 -and $lastLength -lt 5) { $count-- }

    $title = Get-SafeTitle ([IO.Path]::GetFileNameWithoutExtension($Media.Path))
    $baseTitle = $title
    $suffix = 2
    while ($UsedNames.ContainsKey($title.ToLowerInvariant())) {
        $title = "${baseTitle}_$suffix"
        $suffix++
    }
    $UsedNames[$title.ToLowerInvariant()] = $true

    $digits = [math]::Max(2, $count.ToString().Length)
    $audioKbps = 0
    if (-not $Mute) {
        if ($Media.Channels -eq 1) { $audioKbps = 64 } else { $audioKbps = 96 }
    }

    $jobs = @()
    for ($i = 0; $i -lt $count; $i++) {
        $start = $i * $segmentSeconds
        $duration = [math]::Min($segmentSeconds, $Media.Duration - $start)
        # If a tiny tail was merged into this part, keep that tail in the part
        # instead of dropping it.
        if ($i -eq ($count - 1)) { $duration = $Media.Duration - $start }
        if ($duration -le 0.2) { continue }

        $plan = Get-EncodePlan -DurationSec $duration -TargetMB $TargetMB -AudioKbps $audioKbps `
            -Mute $Mute -Width $Media.Width -Height $Media.Height -Fps $Media.Fps -Hdr ([bool]$Media.Hdr)

        $number = $i + 1
        $fileName = '{0}_part{1}_of_{2}.mp4' -f $title, $number.ToString("D$digits"), $count.ToString("D$digits")

        $jobs += [pscustomobject]@{
            Source         = $Media.Path
            Output         = (Join-Path $OutDir $fileName)
            FileName       = $fileName
            Title          = $title
            PartNumber     = $number
            TotalParts     = $count
            Start          = $start
            Duration       = $duration
            SegmentMinutes = $SegmentMinutes
            Channels       = $Media.Channels
            Plan           = $plan
        }
    }
    return $jobs
}

function Get-PartStatePath {
    param([string]$OutDir)
    return (Join-Path $OutDir '.videomail-parts.txt')
}

function Read-PartState {
    param([string]$OutDir)
    # One line per finished part: file name <TAB> settings fingerprint.
    $state = @{}
    $path = Get-PartStatePath $OutDir
    if (-not (Test-Path -LiteralPath $path)) { return $state }
    foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
        $bits = ([string]$line) -split "`t"
        if ($bits.Count -eq 2 -and $bits[0]) { $state[$bits[0]] = $bits[1] }
    }
    return $state
}

function Save-PartState {
    param([string]$OutDir, [string]$FileName, [string]$Fingerprint)
    $state = Read-PartState $OutDir
    $state[$FileName] = $Fingerprint
    $path = Get-PartStatePath $OutDir
    $lines = [string[]]@($state.Keys | Sort-Object | ForEach-Object { "$_`t$($state[$_])" })
    try {
        # A hidden file cannot be overwritten in place, so unhide it first.
        if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path -Force).Attributes = 'Normal' }
        [IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
        if ($env:OS -eq 'Windows_NT') { (Get-Item -LiteralPath $path -Force).Attributes = 'Hidden' }
    } catch {
        # Not fatal: without the record this part is simply made again next time.
        Write-FileLog ('Could not record finished part: ' + $_.Exception.Message)
    }
}

function Get-JobFingerprint {
    param([pscustomobject]$Job, [string]$Quality)
    # Everything that decides what a part should contain. A finished part is
    # reused only when this matches, so changing mute, size, part length,
    # quality or the source never reuses a stale part. Only a hash is stored.
    $src = Get-Item -LiteralPath $Job.Source
    $key = @(
        'v2', $src.FullName.ToLowerInvariant(), $src.Length, $src.LastWriteTimeUtc.Ticks,
        (Format-Seconds $Job.Start), (Format-Seconds $Job.Duration),
        $Job.Plan.TargetBytes, $Job.Plan.AudioKbps, $Job.Plan.VideoFilter, $Quality
    ) -join '|'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
    } finally {
        $sha.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-ExistingPart {
    param([pscustomobject]$Job, [string]$Fingerprint, [hashtable]$State)
    if (-not (Test-Path -LiteralPath $Job.Output)) { return $false }
    if (-not $State -or [string]$State[$Job.FileName] -ne $Fingerprint) { return $false }
    $size = (Get-Item -LiteralPath $Job.Output).Length
    return ($size -gt 1000 -and $size -le ($Job.Plan.TargetBytes * 1.01))
}

function Get-EncoderCandidates {
    param([string]$Quality, [string]$Preset, [string]$Mode = 'auto')

    $cpu1 = [pscustomobject]@{ Id = 'x264'; Name = (Get-Str 'encCpu1'); Gpu = $false; TwoPass = $false; Preset = $Preset; PixFmt = 'yuv420p' }
    $cpu2 = [pscustomobject]@{ Id = 'x264'; Name = (Get-Str 'encCpu2'); Gpu = $false; TwoPass = $true; Preset = $Preset; PixFmt = 'yuv420p' }

    # "Best" keeps the slow two-pass x264 encode: it gives the most quality
    # per megabyte. The other settings take the graphics chip when it works.
    if ($Quality -eq 'best') { return @($cpu2) }
    if ($Mode -eq 'cpu') { return @($cpu1) }

    $gpu = @(
        @('nvenc', 'NVIDIA NVENC'),
        @('nvenc-basic', 'NVIDIA NVENC'),
        @('qsv', 'Intel Quick Sync'),
        @('amf', 'AMD AMF')
    ) | ForEach-Object {
        [pscustomobject]@{ Id = $_[0]; Name = ((Get-Str 'encGpu') -f $_[1]); Gpu = $true; TwoPass = $false; Preset = ''; PixFmt = 'nv12' }
    }
    return @($gpu) + @($cpu1)
}

function Get-EncoderFilter {
    param([pscustomobject]$Plan, [pscustomobject]$Encoder)
    return ($Plan.VideoFilter -replace 'format=yuv420p$', ('format=' + $Encoder.PixFmt))
}

function Get-VideoEncoderArgs {
    param([pscustomobject]$Encoder, [int]$Kbps)

    $b = '{0}k' -f $Kbps
    # Peak-rate cap: keeps every part close to its budget in one pass.
    $vbv = @('-b:v', $b, '-maxrate', ('{0}k' -f [int]($Kbps * 1.5)), '-bufsize', ('{0}k' -f ($Kbps * 2)))
    switch ($Encoder.Id) {
        'nvenc' {
            return @('-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr',
                '-multipass', 'qres', '-spatial-aq', '1', '-rc-lookahead', '20', '-profile:v', 'high') + $vbv
        }
        'nvenc-basic' {
            # Older NVIDIA cards / drivers without multipass or lookahead.
            return @('-c:v', 'h264_nvenc', '-preset', 'p4', '-rc', 'vbr', '-profile:v', 'high') + $vbv
        }
        'qsv' {
            return @('-c:v', 'h264_qsv', '-preset', 'slow', '-profile:v', 'high') + $vbv
        }
        'amf' {
            return @('-c:v', 'h264_amf', '-usage', 'transcoding', '-quality', 'quality',
                '-rc', 'vbr_peak', '-profile:v', 'high') + $vbv
        }
    }
    $x264 = @('-c:v', 'libx264', '-preset', $Encoder.Preset, '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p')
    if ($Encoder.TwoPass) { return $x264 + @('-b:v', $b) }
    return $x264 + $vbv
}

function Select-VideoEncoder {
    param([pscustomobject]$Job, [string]$Quality, [string]$Preset, [string]$Mode)

    $candidates = @(Get-EncoderCandidates -Quality $Quality -Preset $Preset -Mode $Mode)
    $key = "$Quality|$Mode"
    if ($script:EncoderCache.ContainsKey($key)) {
        $hit = @($candidates | Where-Object { $_.Id -eq $script:EncoderCache[$key] }) | Select-Object -First 1
        if ($hit) { return $hit }
    }
    foreach ($enc in $candidates) {
        if (-not $enc.Gpu) {
            $script:EncoderCache[$key] = $enc.Id
            return $enc
        }
        # Encode one second of the real video with the real settings. This
        # proves the chip, the driver and this video's format all work.
        $probe = @(
            '-hide_banner', '-nostdin', '-loglevel', 'error',
            '-ss', (Format-Seconds $Job.Start), '-t', (Format-Seconds ([math]::Min(1.0, $Job.Duration))),
            '-i', $Job.Source, '-map', '0:V:0', '-an', '-vf', (Get-EncoderFilter -Plan $Job.Plan -Encoder $enc)
        ) + @(Get-VideoEncoderArgs -Encoder $enc -Kbps $Job.Plan.VideoKbps) + @('-f', 'null', (Get-NullDevice))
        $r = Invoke-FFmpegCapture -Arguments $probe -TimeoutMs 30000
        if ($r.ExitCode -eq 0) {
            $script:EncoderCache[$key] = $enc.Id
            return $enc
        }
        $why = if ($r.TimedOut) { 'timed out' } else { (($r.Text -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 2) -join ' ' }
        Write-FileLog ('Encoder {0} not usable here: {1}' -f $enc.Id, $why)
    }
    throw 'Internal error: no encoder candidates.'
}

function Invoke-EncodeJob {
    param(
        [pscustomobject]$Job,
        [pscustomobject]$Encoder,
        [string]$TempDir,
        [string]$Fingerprint,
        [string]$OutDir
    )

    $plan = $Job.Plan
    $partial = $Job.Output + '.part'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }

    $passLog = Join-Path $TempDir ('pass_' + [guid]::NewGuid().ToString('N'))
    $progress = Join-Path $TempDir 'progress.txt'
    $nullDev = Get-NullDevice
    $vf = Get-EncoderFilter -Plan $plan -Encoder $Encoder

    $common = @(
        '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
        '-ss', (Format-Seconds $Job.Start),
        '-t', (Format-Seconds $Job.Duration),
        '-i', $Job.Source
    )

    $outStart = 0.0
    if ($Encoder.TwoPass) {
        # Pass 1: analysis only.
        $args1 = $common + @('-map', '0:V:0', '-an', '-vf', $vf) +
            @(Get-VideoEncoderArgs -Encoder $Encoder -Kbps $plan.VideoKbps) +
            @('-pass', '1', '-passlogfile', $passLog, '-progress', $progress, '-nostats', '-f', 'null', $nullDev)
        $script:CurPassStart = 0.0
        $script:CurPassLen = 0.45
        Invoke-FFmpeg -Arguments $args1 -ProgressFile $progress -ExpectedSeconds $Job.Duration -OnTick {
            param($frac, $speed, $elapsed)
            Update-OverallProgress -Fraction $frac -Speed $speed -Elapsed $elapsed -Stage (Get-Str 'stageOptimising')
        }
        $outStart = 0.45
    }

    $audio = @('-an')
    if ($plan.AudioKbps -gt 0) {
        $channels = if ($Job.Channels -eq 1) { '1' } else { '2' }
        $audio = @('-map', '0:a:0?', '-c:a', 'aac', '-b:a', ("{0}k" -f $plan.AudioKbps), '-ac', $channels, '-ar', '48000')
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $args2 = $common + @('-map', '0:V:0') + $audio + @('-vf', $vf) +
            @(Get-VideoEncoderArgs -Encoder $Encoder -Kbps $plan.VideoKbps)
        if ($Encoder.TwoPass) { $args2 += @('-pass', '2', '-passlogfile', $passLog) }
        $args2 += @($plan.ColorArgs) + @(
            '-map_metadata', '-1', '-movflags', '+faststart',
            '-progress', $progress, '-nostats', '-f', 'mp4', $partial
        )

        $script:CurPassStart = $outStart
        $script:CurPassLen = 1.0 - $outStart
        Invoke-FFmpeg -Arguments $args2 -ProgressFile $progress -ExpectedSeconds $Job.Duration -OnTick {
            param($frac, $speed, $elapsed)
            Update-OverallProgress -Fraction $frac -Speed $speed -Elapsed $elapsed -Stage (Get-Str 'stageEncoding')
        }

        $size = (Get-Item -LiteralPath $partial).Length
        if ($size -le $plan.TargetBytes) { break }

        if ($attempt -ge 3) {
            Write-AppLog ((Get-Str 'logTooLargeWarn') -f $Job.FileName,
                [math]::Round($size / 1MB, 1), [math]::Round($plan.TargetBytes / 1MB, 1))
            break
        }

        # Too large: encode again at a proportionally lower bitrate. For
        # two-pass x264 only pass 2 runs again; pass-1 analysis stays valid.
        $factor = ($plan.TargetBytes * 0.97) / $size
        $newKbps = [int][math]::Floor($plan.VideoKbps * $factor)
        if ($newKbps -lt 80) { $newKbps = 80 }
        Write-AppLog ((Get-Str 'logRetry') -f $Job.PartNumber, $newKbps)
        $plan.VideoKbps = $newKbps
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    Move-Item -LiteralPath $partial -Destination $Job.Output -Force
    Save-PartState -OutDir $OutDir -FileName $Job.FileName -Fingerprint $Fingerprint
    $finalSize = (Get-Item -LiteralPath $Job.Output).Length
    Write-AppLog ((Get-Str 'logSaved') -f $Job.FileName, (Format-MB $finalSize))
}

function Update-OverallProgress {
    param(
        [double]$Fraction,
        [double]$Speed,
        [double]$Elapsed,
        [string]$Stage
    )

    $overall = 0.0
    if ($script:TotalParts -gt 0) {
        $overall = ($script:CurPartIndex + $script:CurPassStart + ($Fraction * $script:CurPassLen)) / $script:TotalParts
    }
    if ($overall -lt 0) { $overall = 0 }
    if ($overall -gt 1) { $overall = 1 }

    $speedText = ''
    if ($Speed -gt 0) { $speedText = ((Get-Str 'speedTemplate') -f $Speed) }
    # ETA from the work actually encoded in this run: parts reused from an
    # earlier run finish instantly and would make the estimate far too short.
    $etaText = ''
    $etaElapsed = $Elapsed
    if ($script:EtaClock) { $etaElapsed = $script:EtaClock.Elapsed.TotalSeconds }
    $doneHere = $overall - [double]$script:EtaBase
    if ($doneHere -gt 0.02 -and $etaElapsed -gt 3) {
        $eta = ($etaElapsed / $doneHere) * (1.0 - $overall)
        if ($eta -gt 0) { $etaText = ((Get-Str 'etaTemplate') -f (Format-Eta $eta)) }
    }

    $part = [math]::Min($script:CurPartIndex + 1, $script:TotalParts)
    $pct = [int][math]::Round($Fraction * 100)
    $text = (Protect-LtrRuns (((Get-Str 'partOf') -f $part, $script:TotalParts) + " - $Stage $pct%$speedText$etaText"))

    if ($script:HasGui) {
        try {
            $script:UiProgress.Value = [int][math]::Round($overall * 1000)
            $script:UiStatus.Text = $text
            # Shown on the taskbar button, so progress is visible while minimised.
            $title = (Protect-LtrRuns ('{0}%' -f [int][math]::Floor($overall * 100))) + ' - ' + (Get-Str 'windowTitle')
            if ($script:UiForm -and $script:UiForm.Text -ne $title) { $script:UiForm.Text = $title }
        } catch { }
        try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    } else {
        $shown = [int][math]::Floor($overall * 100)
        if ($shown -ge ($script:LastPercentShown + 2) -or $shown -ge 100) {
            $script:LastPercentShown = $shown
            Write-Host ("[{0,3}%] {1}" -f $shown, $text)
        }
    }
}

function Group-JobsForEmail {
    param([object[]]$Jobs, [double]$MaxBytes)
    $groups = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.ArrayList
    $currentBytes = 0.0

    foreach ($job in $Jobs) {
        $size = (Get-Item -LiteralPath $job.Output).Length
        if ($current.Count -gt 0 -and ($currentBytes + $size) -gt $MaxBytes) {
            [void]$groups.Add(@($current.ToArray()))
            $current.Clear()
            $currentBytes = 0
        }
        [void]$current.Add($job)
        $currentBytes += $size
    }
    if ($current.Count -gt 0) { [void]$groups.Add(@($current.ToArray())) }
    return ,$groups
}

function Get-PrettyTitle {
    param([string]$Title)
    return ($Title -replace '_', ' ')
}

function Get-DraftSubject {
    param([object[]]$Group)
    $Group = @($Group)
    $titles = @($Group | ForEach-Object { $_.Title } | Select-Object -Unique)
    $first = $Group[0].PartNumber
    $last = $Group[-1].PartNumber
    $total = $Group[0].TotalParts

    if ($titles.Count -eq 1) {
        $title = Get-PrettyTitle $titles[0]
        if ($total -eq 1) { return $title }
        if ($Group.Count -eq 1) { return ((Get-Str 'subjPart') -f $title, $first, $total) }
        return ((Get-Str 'subjRange') -f $title, $first, $last, $total)
    }
    if ($Group.Count -eq 1) { return ((Get-Str 'subjMultiPart') -f $first) }
    return ((Get-Str 'subjMultiRange') -f $first, $last)
}

function Get-DraftBody {
    param([object[]]$Group, [string]$Greeting)
    $Group = @($Group)
    $lines = New-Object System.Collections.ArrayList
    if ($Greeting -and $Greeting.Trim()) {
        [void]$lines.Add($Greeting.Trim())
        [void]$lines.Add('')
    }

    $titles = @($Group | ForEach-Object { $_.Title } | Select-Object -Unique)
    $first = $Group[0].PartNumber
    $last = $Group[-1].PartNumber
    $total = $Group[0].TotalParts
    $minutes = $Group[0].SegmentMinutes
    $minuteText = if ([math]::Abs($minutes - 1) -lt 0.01) {
        (Get-Str 'aboutOneMinute')
    } else {
        (Get-Str 'aboutMinutes') -f $minutes
    }

    if ($titles.Count -eq 1) {
        $title = Get-PrettyTitle $titles[0]
        if ($total -eq 1) {
            [void]$lines.Add(((Get-Str 'bodyAttached') -f $title, $minuteText))
        } elseif ($Group.Count -eq 1) {
            [void]$lines.Add(((Get-Str 'bodyPart') -f $first, $total, $title, $minuteText))
        } else {
            [void]$lines.Add(((Get-Str 'bodyRange') -f $first, $last, $title, $total, $minuteText))
        }
    } else {
        [void]$lines.Add(((Get-Str 'bodyMulti') -f $Group.Count))
    }

    [void]$lines.Add('')
    [void]$lines.Add((Get-Str 'attachedFiles'))
    foreach ($job in $Group) {
        $size = (Get-Item -LiteralPath $job.Output).Length
        [void]$lines.Add(("- {0} ({1}, {2})" -f $job.FileName, (Format-Duration $job.Duration), (Format-MB $size)))
    }
    [void]$lines.Add('')
    return ($lines -join "`r`n")
}

function New-OutlookDrafts {
    param(
        [object[]]$Groups,
        [string]$Greeting,
        [string]$To,
        [string]$OutDir
    )

    $made = 0
    $outlook = $null
    $mail = $null

    try {
        $outlook = New-Object -ComObject Outlook.Application
        $null = $outlook.GetNamespace('MAPI')

        foreach ($group in $Groups) {
            if ($script:CancelRequested) { throw 'Cancelled' }

            $mail = $outlook.CreateItem(0)
            $mail.Subject = Get-DraftSubject -Group $group
            $mail.Body = Get-DraftBody -Group $group -Greeting $Greeting
            if ($To) { $mail.To = $To }
            foreach ($job in $group) {
                [void]$mail.Attachments.Add($job.Output)
            }
            $mail.Save()
            $made++

            if ($script:HasGui) {
                $script:UiStatus.Text = (Get-Str 'creatingDraftsCount') -f $made, $Groups.Count
                try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($mail)
            $mail = $null
        }

        return [pscustomobject]@{ Mode = 'outlook'; Count = $made; Dir = ''; Error = '' }
    } catch {
        $reason = $_.Exception.Message
        Write-AppLog ((Get-Str 'logOutlookFailed') -f $reason)

        if ($made -gt 0) {
            return [pscustomobject]@{ Mode = 'outlook-partial'; Count = $made; Dir = ''; Error = $reason }
        }

        # Fallback: write ready-to-forward .eml files. Works even with the new
        # Outlook, which has no automation interface.
        $emlDir = Join-Path $OutDir 'Email drafts - open and forward'
        if (-not (Test-Path -LiteralPath $emlDir)) {
            New-Item -ItemType Directory -Path $emlDir -Force | Out-Null
        }

        $client = New-Object System.Net.Mail.SmtpClient
        $client.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::SpecifiedPickupDirectory
        $client.PickupDirectoryLocation = $emlDir

        $n = 0
        foreach ($group in $Groups) {
            $n++
            $before = @(Get-ChildItem -LiteralPath $emlDir -Filter '*.eml' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

            $msg = New-Object System.Net.Mail.MailMessage
            $msg.From = New-Object System.Net.Mail.MailAddress('videomail@localhost', 'VideoMail')
            $msg.Subject = Get-DraftSubject -Group $group
            $msg.Body = Get-DraftBody -Group $group -Greeting $Greeting
            $msg.BodyEncoding = [System.Text.Encoding]::UTF8
            $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
            if ($To) {
                foreach ($addr in ($To -split '[;,]')) {
                    if ($addr.Trim()) { $msg.To.Add($addr.Trim()) }
                }
            } else {
                # Placeholder so SmtpClient accepts the message; the header is
                # removed below, leaving the recipient for the user to fill in.
                $msg.To.Add('videomail@localhost')
            }
            foreach ($job in $group) {
                $att = New-Object System.Net.Mail.Attachment($job.Output)
                $msg.Attachments.Add($att)
            }

            $client.Send($msg)
            $msg.Dispose()

            $after = @(Get-ChildItem -LiteralPath $emlDir -Filter '*.eml' | Select-Object -ExpandProperty FullName)
            $newFile = @($after | Where-Object { $before -notcontains $_ }) | Select-Object -First 1
            if ($newFile) {
                $text = [IO.File]::ReadAllText($newFile)
                if (-not $To) { $text = $text -replace '(?m)^To:[^\r\n]*\r?\n', '' }
                $enc = New-Object System.Text.UTF8Encoding($false)
                [IO.File]::WriteAllText($newFile, $text, $enc)

                $safeSubject = Get-SafeTitle (Get-DraftSubject -Group $group)
                $newName = ('Draft_{0:00}_{1}.eml' -f $n, $safeSubject)
                Rename-Item -LiteralPath $newFile -NewName $newName -Force
            }

            if ($script:HasGui) {
                $script:UiStatus.Text = (Get-Str 'creatingEmailsCount') -f $n, $Groups.Count
                try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            }
        }

        return [pscustomobject]@{ Mode = 'eml'; Count = $n; Dir = $emlDir; Error = $reason }
    } finally {
        if ($mail) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($mail) } catch { } }
        if ($outlook) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($outlook) } catch { } }
    }
}
