
function Invoke-Batch {
    param([hashtable]$Config)

    if (-not (Test-Path -LiteralPath $script:Ffmpeg)) {
        throw (Get-Str 'errNoFfmpeg')
    }

    $inputs = @($Config.Inputs)
    if ($inputs.Count -eq 0) { throw (Get-Str 'errNoInputs') }

    $outDir = [string]$Config.OutDir
    if (-not $outDir) {
        $outDir = Join-Path (Split-Path -Parent $inputs[0].Path) 'VideoMail parts'
    }
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $targetMB = [double]$Config.TargetMB
    $minutes = [double]$Config.Minutes
    $mute = [bool]$Config.Mute

    Write-AppLog ((Get-Str 'logStarting') -f $inputs.Count, $targetMB, $minutes, $mute)

    $used = @{}
    $jobs = @()
    foreach ($media in $inputs) {
        $jobs += New-PartJobs -Media $media -OutDir $outDir -TargetMB $targetMB `
            -SegmentMinutes $minutes -Mute $mute -UsedNames $used
    }
    if ($jobs.Count -eq 0) { throw (Get-Str 'errNothing') }

    $script:TotalParts = $jobs.Count
    $script:CurPartIndex = 0
    $script:CurPassStart = 0.0
    $script:CurPassLen = 0.0
    $script:LastPercentShown = -1
    Update-OverallProgress -Fraction 0 -Speed 0 -Elapsed 0 -Stage (Get-Str 'stagePreparing')

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('VideoMail_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $preset = Get-QualityPreset -Quality ([string]$Config.Quality)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:JobClock = $clock

    $greeting = [string]$Config.Greeting
    if (-not $greeting.Trim()) { $greeting = (Get-Str 'greetingDefault') }

    try {
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            if ($script:CancelRequested) { throw 'Cancelled' }
            $script:CurPartIndex = $i
            $script:CurPassStart = 0.0
            $script:CurPassLen = 0.0
            Update-OverallProgress -Fraction 0 -Speed 0 -Elapsed $clock.Elapsed.TotalSeconds -Stage (Get-Str 'stageStarting')

            Write-AppLog (((Get-Str 'logPart') -f (Get-Str 'wordPart'), ($i + 1), $jobs.Count, $jobs[$i].FileName))
            Invoke-EncodeJob -Job $jobs[$i] -Preset $preset -TempDir $tempDir

            $script:CurPartIndex = $i + 1
            $script:CurPassStart = 0.0
            $script:CurPassLen = 0.0
            Update-OverallProgress -Fraction 1 -Speed 0 -Elapsed $clock.Elapsed.TotalSeconds -Stage (Get-Str 'stageDone')
        }

        $draftMode = 'none'
        $draftCount = 0
        $draftDir = ''
        $draftError = ''

        if (-not $Config.NoDrafts) {
            $groups = Group-JobsForEmail -Jobs $jobs -MaxBytes (($targetMB * 1000000.0) * 0.98)
            if ($script:HasGui) {
                $script:UiStatus.Text = (Get-Str 'creatingDrafts')
                try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            }
            $r = New-OutlookDrafts -Groups $groups -Greeting $greeting `
                -To ([string]$Config.To) -OutDir $outDir
            $draftMode = $r.Mode
            $draftCount = $r.Count
            $draftDir = $r.Dir
            $draftError = $r.Error
        }

        return [pscustomobject]@{
            Cancelled   = $false
            PartCount   = $jobs.Count
            DraftMode   = $draftMode
            DraftCount  = $draftCount
            DraftDir    = $draftDir
            DraftError  = $draftError
            OutDir      = $outDir
            Seconds     = $clock.Elapsed.TotalSeconds
        }
    } catch {
        $message = $_.Exception.Message
        if ($script:CancelRequested -or $message -eq 'Cancelled') {
            Get-ChildItem -LiteralPath $outDir -Filter '*.part' -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-AppLog (Get-Str 'logCancelledByUser')
            return [pscustomobject]@{
                Cancelled = $true; PartCount = 0; DraftMode = 'none'; DraftCount = 0
                DraftDir = ''; DraftError = ''; OutDir = $outDir; Seconds = $clock.Elapsed.TotalSeconds
            }
        }
        throw
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Cli {
    if (-not $InputPath -or $InputPath.Count -eq 0) {
        Write-Host 'Usage: VideoMail.ps1 -Cli -InputPath <video> [-OutDir <folder>] [-TargetMB 49] [-Minutes 5] [-Mute] [-NoDrafts] [-Language en|fr|de|it|el|ar|fa|he]'
        return 2
    }

    $medias = @()
    foreach ($p in $InputPath) {
        $medias += Get-MediaInfo -VideoPath $p
        Write-Host (((Get-Str 'cliInput') -f (Split-Path -Leaf $p), (Format-Duration $medias[-1].Duration), $medias[-1].Width, $medias[-1].Height))
    }

    $resolvedOut = $OutDir
    if (-not $resolvedOut) {
        $resolvedOut = Join-Path (Split-Path -Parent $medias[0].Path) 'VideoMail parts'
    }

    $config = @{
        Inputs   = $medias
        OutDir   = $resolvedOut
        TargetMB = $TargetMB
        Minutes  = $Minutes
        Quality  = $Quality
        Mute     = [bool]$Mute
        Greeting = $Greeting
        To       = $To
        NoDrafts = [bool]$NoDrafts
    }

    $result = Invoke-Batch -Config $config
    if ($result.Cancelled) {
        Write-Host (Get-Str 'cliCancelled')
        return 1
    }

    Write-Host ''
    Write-Host (((Get-Str 'cliDone') -f $result.PartCount, $result.OutDir, ($result.Seconds / 60)))
    if ($result.DraftMode -eq 'outlook') { Write-Host (((Get-Str 'cliOutlook') -f $result.DraftCount)) }
    elseif ($result.DraftMode -eq 'eml') { Write-Host (((Get-Str 'cliEml') -f $result.DraftCount, $result.DraftDir)) }
    elseif ($result.DraftMode -eq 'outlook-partial') { Write-Host (((Get-Str 'cliPartial') -f $result.DraftCount, $result.DraftError)) }
    return 0
}

function Invoke-SelfTest {
    $script:TestCount = 0
    $script:TestFailures = 0

    function Assert-True {
        param([bool]$Condition, [string]$Name)
        $script:TestCount++
        if (-not $Condition) {
            $script:TestFailures++
            Write-Host "FAIL: $Name" -ForegroundColor Red
        }
    }
    function Assert-Equal {
        param($Actual, $Expected, [string]$Name)
        $script:TestCount++
        if ("$Actual" -ne "$Expected") {
            $script:TestFailures++
            Write-Host "FAIL: $Name (got '$Actual', expected '$Expected')" -ForegroundColor Red
        }
    }

    Set-AppLanguage 'en'

    Assert-Equal (Get-SafeTitle 'My Trip: Day 1?') 'My_Trip_Day_1' 'safe title'
    Assert-Equal (Get-SafeTitle '') 'video' 'empty title'
    Assert-Equal (Get-SafeTitle ('F' + [char]0x00E9 + 'rias 2026')) 'Ferias_2026' 'accent folding'
    Assert-Equal (Get-SafeTitle ('A' + [char]0x00E7 + [char]0x00E3 + 'o')) 'Acao' 'cedilla folding'
    Assert-Equal (Get-SafeTitle ([char]0x0635 + [char]0x064A + [char]0x062F)) 'video' 'arabic-only title falls back'
    Assert-Equal (Get-SafeTitle ([char]0x03C8 + [char]0x03AC + [char]0x03C1 + [char]0x03B5 + [char]0x03BC + [char]0x03B1 + ' 2026')) '2026' 'greek title keeps digits'
    Assert-Equal (Format-MB 49000000) '49.0 MB' 'decimal megabytes'
    Assert-Equal (Format-Duration 300) '5:00' 'duration 5 min'
    Assert-Equal (Format-Duration 3661) '1:01:01' 'duration 1 hour'
    Assert-Equal (Get-QualityPreset 'best') 'medium' 'preset best'
    Assert-Equal (Get-QualityPreset 'fast') 'veryfast' 'preset fast'

    $fit = Test-TargetFit -DurationSec 300 -TargetMB 49 -AudioKbps 96 -Mute $false
    Assert-True ($fit.Fits) '49 MB estimate fits'
    Assert-True ($fit.Plan.VideoKbps -gt 1000) 'video budget is sane'
    $p1080 = Get-EncodePlan -DurationSec 300 -TargetMB 49 -AudioKbps 96 -Mute $false -Width 1920 -Height 1080 -Fps 30
    Assert-True ($p1080.VideoFilter -match 'scale=1280:720') '1080p scales to 720p'

    $muted = Get-EncodePlan -DurationSec 300 -TargetMB 49 -AudioKbps 96 -Mute $true -Width 1920 -Height 1080 -Fps 30
    Assert-Equal $muted.AudioKbps 0 'muted audio budget'
    Assert-True ($muted.VideoKbps -gt $fit.Plan.VideoKbps) 'mute gives video more bits'

    $fake = @(
        [pscustomobject]@{ Title = 'Trip'; PartNumber = 1; TotalParts = 12; SegmentMinutes = 5; FileName = 'Trip_part01_of_12.mp4'; Duration = 300; Output = $PSCommandPath },
        [pscustomobject]@{ Title = 'Trip'; PartNumber = 2; TotalParts = 12; SegmentMinutes = 5; FileName = 'Trip_part02_of_12.mp4'; Duration = 300; Output = $PSCommandPath }
    )
    Assert-Equal (Get-DraftSubject -Group $fake) 'Trip - partitions 1-2 of 12' 'draft subject'
    $body = Get-DraftBody -Group $fake -Greeting 'Hello Fred,'
    Assert-True ($body -match 'Hello Fred,') 'greeting in body'
    Assert-True ($body -match 'partitions 1-2 of "Trip"') 'range in body'

    Set-AppLanguage 'fr'
    Assert-Equal (Get-DraftSubject -Group $fake) 'Trip - parties 1-2 sur 12' 'french draft subject'
    $bodyFr = Get-DraftBody -Group $fake -Greeting (Get-Str 'greetingDefault')
    Assert-True ($bodyFr -match 'Bonjour,') 'french default greeting'
    Assert-True ($bodyFr -match 'parties 1 à 2') 'french range in body'
    Set-AppLanguage 'en'

    Set-AppLanguage 'ar'
    $iso = Protect-LtrRuns '1.90 GB'
    Assert-True ($iso.Contains([string][char]0x2066)) 'rtl isolates number runs'
    Assert-True ((Protect-LtrRuns 'رحلة 2026.mp4') -match '2026\.mp4') 'rtl keeps filename run intact'
    Set-AppLanguage 'en'
    Assert-Equal (Protect-LtrRuns '1.90 GB') '1.90 GB' 'ltr text untouched'

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vmtest_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $bytes = New-Object byte[] 1000
        $f1 = Join-Path $tmp 'a.mp4'; [IO.File]::WriteAllBytes($f1, $bytes)
        $f2 = Join-Path $tmp 'b.mp4'; [IO.File]::WriteAllBytes($f2, $bytes)
        $fj = @(
            [pscustomobject]@{ Output = $f1; Title = 'A'; PartNumber = 1; TotalParts = 2; Duration = 60; SegmentMinutes = 1; FileName = 'a.mp4' },
            [pscustomobject]@{ Output = $f2; Title = 'A'; PartNumber = 2; TotalParts = 2; Duration = 60; SegmentMinutes = 1; FileName = 'b.mp4' }
        )
        $one = Group-JobsForEmail -Jobs $fj -MaxBytes 5000
        Assert-Equal $one.Count 1 'one email group'
        Assert-Equal $one[0].Count 2 'both parts in group'
        $two = Group-JobsForEmail -Jobs $fj -MaxBytes 1500
        Assert-Equal $two.Count 2 'two email groups'
        $single = Group-JobsForEmail -Jobs @($fj[0]) -MaxBytes 5000
        Assert-Equal $single.Count 1 'single part stays wrapped'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $fakeMedia = [pscustomobject]@{
        Path = (Join-Path $tmp 'Fishing trip.mp4'); Duration = 3600; Width = 1920; Height = 1080
        Fps = 30; Channels = 2; Size = 1000000
    }
    $jobs12 = @(New-PartJobs -Media $fakeMedia -OutDir $tmp -TargetMB 49 -SegmentMinutes 5 -Mute $false -UsedNames @{})
    Assert-Equal $jobs12.Count 12 'one hour makes 12 parts'
    Assert-Equal $jobs12[0].FileName 'Fishing_trip_part01_of_12.mp4' 'part naming'
    Assert-Equal $jobs12[0].Duration 300 'regular part length'
    Assert-Equal $jobs12[11].Start 3300 'last part starts at 55 min'

    $shortTail = [pscustomobject]@{
        Path = (Join-Path $tmp 'short tail.mp4'); Duration = 601; Width = 1280; Height = 720
        Fps = 30; Channels = 1; Size = 1000000
    }
    $tailJobs = @(New-PartJobs -Media $shortTail -OutDir $tmp -TargetMB 49 -SegmentMinutes 5 -Mute $true -UsedNames @{})
    Assert-Equal $tailJobs.Count 2 '2-second tail is merged'
    Assert-Equal $tailJobs[1].Duration 301 'merged tail is longer'

    $settingsPath = Join-Path $tmp 'settings.txt'
    [void](Write-AppSetting 'language' 'fr' -Path $settingsPath)
    Assert-Equal (Read-AppSetting 'language' -Paths @($settingsPath)) 'fr' 'settings write and read'
    [void](Write-AppSetting 'language' 'de' -Path $settingsPath)
    Assert-Equal (Read-AppSetting 'language' -Paths @($settingsPath)) 'de' 'settings overwrite'
    Assert-Equal (Read-AppSetting 'missing' -Paths @($settingsPath)) '' 'missing setting is empty'

    $rtlCodes = @('ar', 'fa', 'he')
    foreach ($code in $script:LangCodes) {
        $table = $script:LangTable[$code]
        Assert-True ($table.Native.Length -gt 0) "native name ($code)"
        Assert-Equal ($table.Rtl -eq $true) ($rtlCodes -contains $code) "rtl flag ($code)"
        $missing = @($script:LangTable.en.Keys | Where-Object { -not $table.ContainsKey($_) -or "$($table[$_])".Trim() -eq '' })
        Assert-Equal $missing.Count 0 "complete strings ($code) missing: $($missing -join ', ')"
    }
    Assert-Equal $script:LangCodes.Count 8 'eight languages'

    if ($script:TestFailures -eq 0) {
        Write-Host "Self-test passed ($script:TestCount checks)."
        return 0
    }
    Write-Host "$script:TestFailures of $script:TestCount checks failed."
    return 1
}

if ($SelfTest) {
    exit (Invoke-SelfTest)
}

if ($Cli -or $InputPath) {
    $script:HasGui = $false
    try {
        exit (Invoke-Cli)
    } catch {
        Write-Host ''
        Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Log:   ' + $script:LogPath)
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $script:Ffmpeg)) {
    Add-Type -AssemblyName System.Windows.Forms
    [void](Show-MsgBox ((Get-Str 'errNoFfmpeg') + "`r`n`r`n" + (Get-Str 'errNoFfmpeg2')) 'VideoMail' 'OK' 'Error')
    exit 1
}

try {
    # Show-Gui returns true when the language was changed in Options; the
    # window is then rebuilt in the new language (and direction).
    do {
        $restart = Show-Gui
    } while ($restart)
} catch {
    Write-AppLog ("FATAL: " + $_.Exception.Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void](Show-MsgBox ((Get-Str 'errFatal1') + "`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + (Get-Str 'errFatal2') + $script:LogPath) 'VideoMail' 'OK' 'Error')
    } catch { }
    exit 1
}
