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
# Interface strings. English is the baseline; the self-test checks that every
# language defines the same keys. Rtl marks right-to-left languages, which get
# a mirrored window.

$script:LangCodes = @('en', 'fr', 'de', 'it', 'el', 'ar', 'fa', 'he')

$script:LangTable = @{
    en = @{
        Rtl = $false; Native = 'English'
        optError = 'Could not open Options:'
        windowTitle = 'VideoMail - long videos to email'
        subtitle = 'Long videos in. Email-sized parts and ready-to-send drafts out.'
        options = 'Options'
        dragHere = 'Drag videos here'
        dropHint = 'or click to choose files (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'Video'; colLength = 'Length'; colSize = 'Size'; colParts = 'Parts'
        removeFromList = 'Remove from list'
        summaryIdle = 'Drop a video above, then press the green button.'
        summaryTemplate = '{0}, {1} total - {2}'
        videosCount = '{0} video(s)'
        emailParts = 'about {0} email parts'
        ready = 'Ready.'
        readyGo = 'Ready. Press the green button when you are ready.'
        go = 'Split & prepare emails'
        mute = 'Remove sound (mute)'
        cancel = 'Cancel'
        cancelling = 'Cancelling...'
        cancelledStatus = 'Cancelled.'
        cancelledMsg = 'Cancelled. Partial files were removed.'
        doneStatus = 'Done.'
        somethingWrong = 'Something went wrong:'
        dropFirst = 'Drop a video first, or click the blue area to choose one.'
        chooseVideos = 'Choose videos'
        filterVideos = 'Videos'; filterAll = 'All files'
        reading = 'Reading {0}...'
        noVideosFound = 'No video files found in:'
        couldNotRead = 'Could not read:'
        cannotWrite1 = 'I cannot write to:'
        cannotWrite2 = 'Choose another folder under Options.'
        workingClose = 'A job is still running. Stop it and close VideoMail?'
        creatingDrafts = 'Creating Outlook drafts...'
        creatingDraftsCount = 'Creating Outlook drafts... ({0} of {1})'
        creatingEmailsCount = 'Creating ready-to-send emails... ({0} of {1})'
        doneBox1 = 'Done!'
        donePartsSaved = '{0} part(s) saved in:'
        doneOutlook1 = '{0} draft(s) are waiting in Outlook Drafts.'
        doneOutlook2 = 'Open Outlook, check them, and press Send on each one.'
        donePartial1 = '{0} draft(s) were created, but Outlook then reported: {1}'
        donePartial2 = 'Check the Drafts folder, then run again for the rest.'
        doneEml1 = 'Outlook automation is not available on this PC, so {0} ready-to-send email file(s) were saved in:'
        doneEml2 = 'Open one, click Forward, add the recipient, and press Send.'
        doneNoDrafts = 'Drafts were skipped.'
        doneHint = 'If Outlook refuses to send one as too large, set 35 MB in Options and run again.'
        optLanguage = 'Language'
        optMaxSize = 'Maximum size per email'
        mb = 'MB'
        optPartLength = 'Part length'
        minutes = 'minutes'
        optQuality = 'Quality'
        qualityBest = 'Best quality (slower)'
        qualityBalanced = 'Balanced'
        qualityFast = 'Fastest'
        optGreeting = 'Greeting'
        optSendTo = 'Send drafts to (optional)'
        optAutoDrafts = 'Create Outlook drafts automatically'
        optSaveIn = 'Save parts in'
        ok = 'OK'
        tip = 'Tip: if Outlook refuses to send a 49 MB file, choose 35 MB (mail encoding adds about a third).'
        stagePreparing = 'preparing'
        stageStarting = 'starting'
        stageOptimising = 'optimising'
        stageEncoding = 'encoding'
        stageDone = 'done'
        partOf = 'Part {0} of {1}'
        wordPart = 'Part'
        speedTemplate = ' - {0:0.0}x speed'
        etaSoon = 'less than a minute'
        etaMinutes = 'about {0} min'
        etaHours = 'about {0} h {1} min'
        etaTemplate = ' - {0} left'
        logStarting = 'Starting: {0} video(s), {1} MB per email, {2} minute parts, mute={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'Saved {0} - {1}'
        logReuse = 'Reusing existing part: {0}'
        logRetry = 'Part {0} came out too large; retrying at {1} kbps.'
        logTooLargeWarn = 'Warning: {0} is still {1} MB (target {2} MB).'
        logOutlookFailed = 'Outlook automation failed: {0}'
        logCancelledByUser = 'Cancelled by user.'
        greetingDefault = 'Hello,'
        subjPart = '{0} - partition {1} of {2}'
        subjRange = '{0} - partitions {1}-{2} of {3}'
        subjMultiPart = 'Video partition {0}'
        subjMultiRange = 'Video partitions {0}-{1}'
        aboutOneMinute = 'about 1 minute'
        aboutMinutes = 'about {0} minutes'
        bodyAttached = 'Please find attached "{0}" ({1}).'
        bodyPart = 'Please find below partition {0} of {1} of "{2}" ({3}).'
        bodyRange = 'Please find below the partitions {0}-{1} of "{2}" ({3} partitions in total, {4} each).'
        bodyMulti = 'Please find below {0} video partitions.'
        attachedFiles = 'Attached files:'
        errNotFound = 'File not found: {0}'
        errNotVideo = 'This file could not be read as a video: {0}'
        errNoVideoTrack = 'No video track found in: {0}'
        errNoFrameSize = 'Could not read the frame size of: {0}'
        errTooSmall = '{0} MB is too small for a {1} minute part. Increase the size per email, or make the parts shorter.'
        errShortPart = 'Part length must be at least a few seconds.'
        errEncoder = 'The video encoder failed. {0}'
        errNoFfmpeg = 'ffmpeg.exe is missing. Keep it in the same folder as VideoMail.ps1.'
        errNoFfmpeg2 = 'Keep VideoMail.ps1 and ffmpeg.exe together in the same folder.'
        errNoInputs = 'No videos were added.'
        errNothing = 'There was nothing to encode.'
        errFatal1 = 'VideoMail could not start:'
        errFatal2 = 'Details: '
        cliInput = 'Input: {0} - {1}, {2}x{3}'
        cliDone = 'Done: {0} part(s) in {1} ({2:0.0} min)'
        cliOutlook = '{0} Outlook draft(s) created.'
        cliEml = '{0} ready-to-send .eml file(s): {1}'
        cliPartial = '{0} draft(s) created, then: {1}'
        cliCancelled = 'Cancelled.'
    }
    fr = @{
        Rtl = $false; Native = 'Français'
        optError = 'Impossible d''ouvrir les Options :'
        windowTitle = 'VideoMail - envoyer de longues vidéos par e-mail'
        subtitle = 'Des vidéos longues en entrée. Des parties prêtes pour l''e-mail et des brouillons prêts à envoyer en sortie.'
        options = 'Options'
        dragHere = 'Glissez des vidéos ici'
        dropHint = 'ou cliquez pour choisir des fichiers (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'Vidéo'; colLength = 'Durée'; colSize = 'Taille'; colParts = 'Parties'
        removeFromList = 'Retirer de la liste'
        summaryIdle = 'Déposez une vidéo ci-dessus, puis appuyez sur le bouton vert.'
        summaryTemplate = '{0}, {1} au total - {2}'
        videosCount = '{0} vidéo(s)'
        emailParts = 'environ {0} parties'
        ready = 'Prêt.'
        readyGo = 'Prêt. Appuyez sur le bouton vert quand vous êtes prêt.'
        go = 'Découper et préparer les e-mails'
        mute = 'Supprimer le son (muet)'
        cancel = 'Annuler'
        cancelling = 'Annulation...'
        cancelledStatus = 'Annulé.'
        cancelledMsg = 'Annulé. Les fichiers incomplets ont été supprimés.'
        doneStatus = 'Terminé.'
        somethingWrong = 'Une erreur est survenue :'
        dropFirst = 'Déposez d''abord une vidéo, ou cliquez sur la zone bleue pour en choisir une.'
        chooseVideos = 'Choisir des vidéos'
        filterVideos = 'Vidéos'; filterAll = 'Tous les fichiers'
        reading = 'Lecture de {0}...'
        noVideosFound = 'Aucun fichier vidéo trouvé dans :'
        couldNotRead = 'Lecture impossible :'
        cannotWrite1 = 'Impossible d''écrire dans :'
        cannotWrite2 = 'Choisissez un autre dossier dans les Options.'
        workingClose = 'Un travail est encore en cours. L''arrêter et fermer VideoMail ?'
        creatingDrafts = 'Création des brouillons Outlook...'
        creatingDraftsCount = 'Création des brouillons Outlook... ({0} sur {1})'
        creatingEmailsCount = 'Création des e-mails prêts à envoyer... ({0} sur {1})'
        doneBox1 = 'Terminé !'
        donePartsSaved = '{0} partie(s) enregistrée(s) dans :'
        doneOutlook1 = '{0} brouillon(s) attendent dans les Brouillons d''Outlook.'
        doneOutlook2 = 'Ouvrez Outlook, vérifiez-les, puis appuyez sur Envoyer pour chacun.'
        donePartial1 = '{0} brouillon(s) ont été créés, mais Outlook a ensuite signalé : {1}'
        donePartial2 = 'Vérifiez le dossier Brouillons, puis relancez pour la suite.'
        doneEml1 = 'L''automation d''Outlook n''est pas disponible sur ce PC, donc {0} fichier(s) e-mail prêt(s) à envoyer ont été enregistrés dans :'
        doneEml2 = 'Ouvrez-en un, cliquez sur Transférer, ajoutez le destinataire et envoyez.'
        doneNoDrafts = 'La création des brouillons a été ignorée.'
        doneHint = 'Si Outlook refuse un envoi pour cause de taille, mettez 35 Mo dans les Options et relancez.'
        optLanguage = 'Langue'
        optMaxSize = 'Taille max. par e-mail'
        mb = 'Mo'
        optPartLength = 'Durée des parties'
        minutes = 'minutes'
        optQuality = 'Qualité'
        qualityBest = 'Meilleure qualité (plus lent)'
        qualityBalanced = 'Équilibré'
        qualityFast = 'La plus rapide'
        optGreeting = 'Salutation'
        optSendTo = 'Envoyer les brouillons à (facultatif)'
        optAutoDrafts = 'Créer les brouillons Outlook automatiquement'
        optSaveIn = 'Enregistrer les parties dans'
        ok = 'OK'
        tip = 'Astuce : si Outlook refuse un fichier de 49 Mo, choisissez 35 Mo (le codage des e-mails ajoute environ un tiers).'
        stagePreparing = 'préparation'
        stageStarting = 'démarrage'
        stageOptimising = 'optimisation'
        stageEncoding = 'encodage'
        stageDone = 'terminé'
        partOf = 'Partie {0} de {1}'
        wordPart = 'Partie'
        speedTemplate = ' - vitesse {0:0.0}x'
        etaSoon = 'moins d''une minute'
        etaMinutes = 'environ {0} min'
        etaHours = 'environ {0} h {1} min'
        etaTemplate = ' - {0} restantes'
        logStarting = 'Début : {0} vidéo(s), {1} Mo par e-mail, parties de {2} minutes, muet={3}'
        logPart = '{0} {1}/{2} : {3}'
        logSaved = 'Enregistré {0} - {1}'
        logReuse = 'Réutilisation d''une partie existante : {0}'
        logRetry = 'La partie {0} est trop lourde ; nouvel essai à {1} kbps.'
        logTooLargeWarn = 'Attention : {0} fait toujours {1} Mo (cible {2} Mo).'
        logOutlookFailed = 'L''automation d''Outlook a échoué : {0}'
        logCancelledByUser = 'Annulé par l''utilisateur.'
        greetingDefault = 'Bonjour,'
        subjPart = '{0} - partie {1} sur {2}'
        subjRange = '{0} - parties {1}-{2} sur {3}'
        subjMultiPart = 'Partie de vidéo {0}'
        subjMultiRange = 'Parties de vidéo {0}-{1}'
        aboutOneMinute = 'environ 1 minute'
        aboutMinutes = 'environ {0} minutes'
        bodyAttached = 'Vous trouverez en pièce jointe « {0} » ({1}).'
        bodyPart = 'Voici la partie {0} sur {1} de « {2} » ({3}).'
        bodyRange = 'Voici les parties {0} à {1} de « {2} » ({3} parties au total, {4} chacune).'
        bodyMulti = 'Voici {0} parties de vidéo.'
        attachedFiles = 'Fichiers joints :'
        errNotFound = 'Fichier introuvable : {0}'
        errNotVideo = 'Ce fichier n''a pas pu être lu comme une vidéo : {0}'
        errNoVideoTrack = 'Aucune piste vidéo dans : {0}'
        errNoFrameSize = 'Impossible de lire la taille de l''image de : {0}'
        errTooSmall = '{0} Mo, c''est trop peu pour une partie de {1} minutes. Augmentez la taille par e-mail ou raccourcissez les parties.'
        errShortPart = 'La durée d''une partie doit être d''au moins quelques secondes.'
        errEncoder = 'L''encodeur vidéo a échoué. {0}'
        errNoFfmpeg = 'ffmpeg.exe est manquant. Gardez-le dans le même dossier que VideoMail.ps1.'
        errNoFfmpeg2 = 'Gardez VideoMail.ps1 et ffmpeg.exe ensemble dans le même dossier.'
        errNoInputs = 'Aucune vidéo n''a été ajoutée.'
        errNothing = 'Il n''y a rien à encoder.'
        errFatal1 = 'VideoMail n''a pas pu démarrer :'
        errFatal2 = 'Détails : '
        cliInput = 'Entrée : {0} - {1}, {2}x{3}'
        cliDone = 'Terminé : {0} partie(s) dans {1} ({2:0.0} min)'
        cliOutlook = '{0} brouillon(s) Outlook créé(s).'
        cliEml = '{0} fichier(s) e-mail prêt(s) à envoyer (.eml) : {1}'
        cliPartial = '{0} brouillon(s) créé(s), puis : {1}'
        cliCancelled = 'Annulé.'
    }
    de = @{
        Rtl = $false; Native = 'Deutsch'
        optError = 'Optionen konnten nicht geöffnet werden:'
        windowTitle = 'VideoMail - lange Videos per E-Mail'
        subtitle = 'Lange Videos rein. E-Mail-gerechte Teile und fertige Entwürfe raus.'
        options = 'Optionen'
        dragHere = 'Videos hierher ziehen'
        dropHint = 'oder klicken, um Dateien auszuwählen (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'Video'; colLength = 'Länge'; colSize = 'Größe'; colParts = 'Teile'
        removeFromList = 'Aus der Liste entfernen'
        summaryIdle = 'Video oben ablegen, dann den grünen Knopf drücken.'
        summaryTemplate = '{0}, {1} insgesamt - {2}'
        videosCount = '{0} Video(s)'
        emailParts = 'etwa {0} E-Mail-Teile'
        ready = 'Bereit.'
        readyGo = 'Bereit. Drücken Sie den grünen Knopf, wenn Sie so weit sind.'
        go = 'Teilen und E-Mails vorbereiten'
        mute = 'Ton entfernen (stumm)'
        cancel = 'Abbrechen'
        cancelling = 'Wird abgebrochen...'
        cancelledStatus = 'Abgebrochen.'
        cancelledMsg = 'Abgebrochen. Unfertige Dateien wurden entfernt.'
        doneStatus = 'Fertig.'
        somethingWrong = 'Etwas ist schiefgelaufen:'
        dropFirst = 'Legen Sie zuerst ein Video ab oder klicken Sie auf den blauen Bereich.'
        chooseVideos = 'Videos auswählen'
        filterVideos = 'Videos'; filterAll = 'Alle Dateien'
        reading = 'Lese {0}...'
        noVideosFound = 'Keine Videodateien gefunden in:'
        couldNotRead = 'Konnte nicht gelesen werden:'
        cannotWrite1 = 'Hier kann nicht geschrieben werden:'
        cannotWrite2 = 'Wählen Sie unter Optionen einen anderen Ordner.'
        workingClose = 'Ein Auftrag läuft noch. Beenden und VideoMail schließen?'
        creatingDrafts = 'Outlook-Entwürfe werden erstellt...'
        creatingDraftsCount = 'Outlook-Entwürfe werden erstellt... ({0} von {1})'
        creatingEmailsCount = 'Fertige E-Mails werden erstellt... ({0} von {1})'
        doneBox1 = 'Fertig!'
        donePartsSaved = '{0} Teil(e) gespeichert in:'
        doneOutlook1 = '{0} Entwürfe warten in den Outlook-Entwürfen.'
        doneOutlook2 = 'Outlook öffnen, prüfen und jeden Entwurf auf Senden drücken.'
        donePartial1 = '{0} Entwürfe wurden erstellt, aber Outlook meldete danach: {1}'
        donePartial2 = 'Prüfen Sie den Entwürfe-Ordner und starten Sie für den Rest erneut.'
        doneEml1 = 'Die Outlook-Automatisierung ist auf diesem PC nicht verfügbar, daher wurden {0} fertige E-Mail-Dateien gespeichert in:'
        doneEml2 = 'Eine öffnen, auf Weiterleiten klicken, Empfänger eintragen und senden.'
        doneNoDrafts = 'Entwürfe wurden übersprungen.'
        doneHint = 'Wenn Outlook eine Datei als zu groß ablehnt, stellen Sie 35 MB in den Optionen ein und starten Sie erneut.'
        optLanguage = 'Sprache'
        optMaxSize = 'Max. Größe pro E-Mail'
        mb = 'MB'
        optPartLength = 'Teil-Länge'
        minutes = 'Minuten'
        optQuality = 'Qualität'
        qualityBest = 'Beste Qualität (langsamer)'
        qualityBalanced = 'Ausgewogen'
        qualityFast = 'Schnellste'
        optGreeting = 'Anrede'
        optSendTo = 'Entwürfe senden an (optional)'
        optAutoDrafts = 'Outlook-Entwürfe automatisch erstellen'
        optSaveIn = 'Teile speichern in'
        ok = 'OK'
        tip = 'Tipp: Lehnt Outlook eine 49-MB-Datei ab, wählen Sie 35 MB (die Mail-Codierung schlägt etwa ein Drittel drauf).'
        stagePreparing = 'Vorbereitung'
        stageStarting = 'Start'
        stageOptimising = 'Optimierung'
        stageEncoding = 'Codierung'
        stageDone = 'fertig'
        partOf = 'Teil {0} von {1}'
        wordPart = 'Teil'
        speedTemplate = ' - Tempo {0:0.0}x'
        etaSoon = 'weniger als eine Minute'
        etaMinutes = 'noch etwa {0} Min.'
        etaHours = 'noch etwa {0} Std. {1} Min.'
        etaTemplate = ' - {0}'
        logStarting = 'Start: {0} Video(s), {1} MB pro E-Mail, {2}-Minuten-Teile, stumm={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'Gespeichert {0} - {1}'
        logReuse = 'Vorhandenes Teil wird wiederverwendet: {0}'
        logRetry = 'Teil {0} wurde zu groß; neuer Versuch mit {1} kbps.'
        logTooLargeWarn = 'Warnung: {0} ist noch {1} MB (Ziel {2} MB).'
        logOutlookFailed = 'Outlook-Automatisierung fehlgeschlagen: {0}'
        logCancelledByUser = 'Vom Benutzer abgebrochen.'
        greetingDefault = 'Hallo,'
        subjPart = '{0} - Teil {1} von {2}'
        subjRange = '{0} - Teile {1}-{2} von {3}'
        subjMultiPart = 'Videoteil {0}'
        subjMultiRange = 'Videoteile {0}-{1}'
        aboutOneMinute = 'etwa 1 Minute'
        aboutMinutes = 'etwa {0} Minuten'
        bodyAttached = 'Anbei finden Sie „{0}“ ({1}).'
        bodyPart = 'Hier ist Teil {0} von {1} von „{2}“ ({3}).'
        bodyRange = 'Hier sind die Teile {0}-{1} von „{2}“ (insgesamt {3} Teile, je {4}).'
        bodyMulti = 'Hier sind {0} Videoteile.'
        attachedFiles = 'Angehängte Dateien:'
        errNotFound = 'Datei nicht gefunden: {0}'
        errNotVideo = 'Diese Datei konnte nicht als Video gelesen werden: {0}'
        errNoVideoTrack = 'Keine Videospur in: {0}'
        errNoFrameSize = 'Die Bildgröße konnte nicht gelesen werden von: {0}'
        errTooSmall = '{0} MB sind zu wenig für ein {1}-Minuten-Teil. Erhöhen Sie die Größe pro E-Mail oder verkürzen Sie die Teile.'
        errShortPart = 'Ein Teil muss mindestens ein paar Sekunden lang sein.'
        errEncoder = 'Der Video-Encoder ist fehlgeschlagen. {0}'
        errNoFfmpeg = 'ffmpeg.exe fehlt. Behalten Sie es im selben Ordner wie VideoMail.ps1.'
        errNoFfmpeg2 = 'Behalten Sie VideoMail.ps1 und ffmpeg.exe zusammen im selben Ordner.'
        errNoInputs = 'Es wurden keine Videos hinzugefügt.'
        errNothing = 'Es gibt nichts zu codieren.'
        errFatal1 = 'VideoMail konnte nicht starten:'
        errFatal2 = 'Details: '
        cliInput = 'Eingabe: {0} - {1}, {2}x{3}'
        cliDone = 'Fertig: {0} Teil(e) in {1} ({2:0.0} Min.)'
        cliOutlook = '{0} Outlook-Entwürfe erstellt.'
        cliEml = '{0} fertige E-Mail-Datei(en) (.eml): {1}'
        cliPartial = '{0} Entwürfe erstellt, danach: {1}'
        cliCancelled = 'Abgebrochen.'
    }
    it = @{
        Rtl = $false; Native = 'Italiano'
        optError = 'Impossibile aprire le Opzioni:'
        windowTitle = 'VideoMail - video lunghi via e-mail'
        subtitle = 'Video lunghi in ingresso. Parti della dimensione giusta per l''e-mail e bozze pronte da inviare.'
        options = 'Opzioni'
        dragHere = 'Trascina qui i video'
        dropHint = 'oppure clicca per scegliere i file (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'Video'; colLength = 'Durata'; colSize = 'Dimensione'; colParts = 'Parti'
        removeFromList = 'Rimuovi dall''elenco'
        summaryIdle = 'Trascina un video qui sopra, poi premi il pulsante verde.'
        summaryTemplate = '{0}, {1} in totale - {2}'
        videosCount = '{0} video'
        emailParts = 'circa {0} parti e-mail'
        ready = 'Pronto.'
        readyGo = 'Pronto. Premi il pulsante verde quando vuoi.'
        go = 'Dividi e prepara le e-mail'
        mute = 'Rimuovi l''audio (muto)'
        cancel = 'Annulla'
        cancelling = 'Annullamento...'
        cancelledStatus = 'Annullato.'
        cancelledMsg = 'Annullato. I file incompleti sono stati rimossi.'
        doneStatus = 'Fatto.'
        somethingWrong = 'Qualcosa è andato storto:'
        dropFirst = 'Prima trascina un video, oppure clicca l''area blu per sceglierne uno.'
        chooseVideos = 'Scegli video'
        filterVideos = 'Video'; filterAll = 'Tutti i file'
        reading = 'Lettura di {0}...'
        noVideosFound = 'Nessun file video trovato in:'
        couldNotRead = 'Impossibile leggere:'
        cannotWrite1 = 'Impossibile scrivere in:'
        cannotWrite2 = 'Scegli un''altra cartella nelle Opzioni.'
        workingClose = 'Un lavoro è ancora in corso. Interromperlo e chiudere VideoMail?'
        creatingDrafts = 'Creazione bozze Outlook...'
        creatingDraftsCount = 'Creazione bozze Outlook... ({0} di {1})'
        creatingEmailsCount = 'Creazione e-mail pronte all''invio... ({0} di {1})'
        doneBox1 = 'Fatto!'
        donePartsSaved = '{0} parti salvate in:'
        doneOutlook1 = '{0} bozze ti aspettano nelle Bozze di Outlook.'
        doneOutlook2 = 'Apri Outlook, controllale e premi Invia su ciascuna.'
        donePartial1 = '{0} bozze sono state create, ma Outlook ha poi segnalato: {1}'
        donePartial2 = 'Controlla la cartella Bozze ed esegui di nuovo per il resto.'
        doneEml1 = 'L''automazione di Outlook non è disponibile su questo PC, quindi {0} file e-mail pronti sono stati salvati in:'
        doneEml2 = 'Aprine uno, clicca Inoltra, aggiungi il destinatario e invia.'
        doneNoDrafts = 'La creazione delle bozze è stata saltata.'
        doneHint = 'Se Outlook rifiuta l''invio per la dimensione, imposta 35 MB nelle Opzioni e riprova.'
        optLanguage = 'Lingua'
        optMaxSize = 'Dimensione max per e-mail'
        mb = 'MB'
        optPartLength = 'Durata delle parti'
        minutes = 'minuti'
        optQuality = 'Qualità'
        qualityBest = 'Qualità migliore (più lento)'
        qualityBalanced = 'Equilibrato'
        qualityFast = 'La più veloce'
        optGreeting = 'Saluto'
        optSendTo = 'Invia le bozze a (facoltativo)'
        optAutoDrafts = 'Crea automaticamente le bozze Outlook'
        optSaveIn = 'Salva le parti in'
        ok = 'OK'
        tip = 'Suggerimento: se Outlook rifiuta un file da 49 MB, scegli 35 MB (la codifica e-mail aggiunge circa un terzo).'
        stagePreparing = 'preparazione'
        stageStarting = 'avvio'
        stageOptimising = 'ottimizzazione'
        stageEncoding = 'codifica'
        stageDone = 'fatto'
        partOf = 'Parte {0} di {1}'
        wordPart = 'Parte'
        speedTemplate = ' - velocità {0:0.0}x'
        etaSoon = 'meno di un minuto'
        etaMinutes = 'circa {0} min'
        etaHours = 'circa {0} h {1} min'
        etaTemplate = ' - {0} rimanenti'
        logStarting = 'Inizio: {0} video, {1} MB per e-mail, parti da {2} minuti, muto={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'Salvato {0} - {1}'
        logReuse = 'Riutilizzo di una parte esistente: {0}'
        logRetry = 'La parte {0} è risultata troppo grande; nuovo tentativo a {1} kbps.'
        logTooLargeWarn = 'Attenzione: {0} è ancora {1} MB (obiettivo {2} MB).'
        logOutlookFailed = 'Automazione di Outlook non riuscita: {0}'
        logCancelledByUser = 'Annullato dall''utente.'
        greetingDefault = 'Ciao,'
        subjPart = '{0} - parte {1} di {2}'
        subjRange = '{0} - parti {1}-{2} di {3}'
        subjMultiPart = 'Parte di video {0}'
        subjMultiRange = 'Parti di video {0}-{1}'
        aboutOneMinute = 'circa 1 minuto'
        aboutMinutes = 'circa {0} minuti'
        bodyAttached = 'In allegato trovi "{0}" ({1}).'
        bodyPart = 'Questa è la parte {0} di {1} di "{2}" ({3}).'
        bodyRange = 'Queste sono le parti {0}-{1} di "{2}" ({3} parti in totale, {4} ciascuna).'
        bodyMulti = 'Queste sono {0} parti di video.'
        attachedFiles = 'File allegati:'
        errNotFound = 'File non trovato: {0}'
        errNotVideo = 'Impossibile leggere questo file come video: {0}'
        errNoVideoTrack = 'Nessuna traccia video in: {0}'
        errNoFrameSize = 'Impossibile leggere la dimensione del fotogramma di: {0}'
        errTooSmall = '{0} MB sono troppo pochi per una parte di {1} minuti. Aumenta la dimensione per e-mail o accorcia le parti.'
        errShortPart = 'La durata di una parte deve essere di almeno qualche secondo.'
        errEncoder = 'Il codificatore video ha fallito. {0}'
        errNoFfmpeg = 'Manca ffmpeg.exe. Tienilo nella stessa cartella di VideoMail.ps1.'
        errNoFfmpeg2 = 'Tieni VideoMail.ps1 e ffmpeg.exe insieme nella stessa cartella.'
        errNoInputs = 'Nessun video aggiunto.'
        errNothing = 'Non c''è niente da codificare.'
        errFatal1 = 'VideoMail non è riuscito ad avviarsi:'
        errFatal2 = 'Dettagli: '
        cliInput = 'Input: {0} - {1}, {2}x{3}'
        cliDone = 'Fatto: {0} parti in {1} ({2:0.0} min)'
        cliOutlook = '{0} bozze Outlook create.'
        cliEml = '{0} file e-mail pronti (.eml): {1}'
        cliPartial = '{0} bozze create, poi: {1}'
        cliCancelled = 'Annullato.'
    }
    el = @{
        Rtl = $false; Native = 'Ελληνικά'
        optError = 'Δεν ήταν δυνατό το άνοιγμα των Επιλογών:'
        windowTitle = 'VideoMail - μεγάλα βίντεο με e-mail'
        subtitle = 'Μεγάλα βίντεο μέσα. Μέρη σε μέγεθος e-mail και πρόχειρα έτοιμα για αποστολή έξω.'
        options = 'Επιλογές'
        dragHere = 'Σύρετε βίντεο εδώ'
        dropHint = 'ή κάντε κλικ για επιλογή αρχείων (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'Βίντεο'; colLength = 'Διάρκεια'; colSize = 'Μέγεθος'; colParts = 'Μέρη'
        removeFromList = 'Αφαίρεση από τη λίστα'
        summaryIdle = 'Ρίξτε ένα βίντεο παραπάνω και πατήστε το πράσινο κουμπί.'
        summaryTemplate = '{0}, συνολικά {1} - {2}'
        videosCount = '{0} βίντεο'
        emailParts = 'περίπου {0} μέρη e-mail'
        ready = 'Έτοιμο.'
        readyGo = 'Έτοιμο. Πατήστε το πράσινο κουμπί όποτε θέλετε.'
        go = 'Διαίρεση και προετοιμασία e-mail'
        mute = 'Αφαίρεση ήχου (σίγαση)'
        cancel = 'Ακύρωση'
        cancelling = 'Ακύρωση...'
        cancelledStatus = 'Ακυρώθηκε.'
        cancelledMsg = 'Ακυρώθηκε. Τα μισοτελειωμένα αρχεία αφαιρέθηκαν.'
        doneStatus = 'Έτοιμο.'
        somethingWrong = 'Κάτι πήγε στραβά:'
        dropFirst = 'Ρίξτε πρώτα ένα βίντεο ή κάντε κλικ στη μπλε περιοχή.'
        chooseVideos = 'Επιλογή βίντεο'
        filterVideos = 'Βίντεο'; filterAll = 'Όλα τα αρχεία'
        reading = 'Ανάγνωση {0}...'
        noVideosFound = 'Δεν βρέθηκαν αρχεία βίντεο στο:'
        couldNotRead = 'Αδύνατη η ανάγνωση:'
        cannotWrite1 = 'Δεν μπορώ να γράψω στο:'
        cannotWrite2 = 'Επιλέξτε άλλον φάκελο στις Επιλογές.'
        workingClose = 'Η εργασία τρέχει ακόμα. Να διακοπεί και να κλείσει το VideoMail;'
        creatingDrafts = 'Δημιουργία πρόχειρων Outlook...'
        creatingDraftsCount = 'Δημιουργία πρόχειρων Outlook... ({0} από {1})'
        creatingEmailsCount = 'Δημιουργία έτοιμων e-mail... ({0} από {1})'
        doneBox1 = 'Έτοιμο!'
        donePartsSaved = 'Αποθηκεύτηκαν {0} μέρη στο:'
        doneOutlook1 = '{0} πρόχειρα περιμένουν στα Πρόχειρα του Outlook.'
        doneOutlook2 = 'Ανοίξτε το Outlook, ελέγξτε τα και πατήστε Αποστολή στο καθένα.'
        donePartial1 = 'Δημιουργήθηκαν {0} πρόχειρα, αλλά το Outlook μετά ανέφερε: {1}'
        donePartial2 = 'Ελέγξτε τον φάκελο Πρόχειρα και τρέξτε ξανά για τα υπόλοιπα.'
        doneEml1 = 'Η αυτοματοποίηση του Outlook δεν είναι διαθέσιμη σε αυτόν τον υπολογιστή, οπότε αποθηκεύτηκαν {0} έτοιμα αρχεία e-mail στο:'
        doneEml2 = 'Ανοίξτε ένα, πατήστε Προώθηση, προσθέστε παραλήπτη και στείλτε.'
        doneNoDrafts = 'Η δημιουργία πρόχειρων παραλείφθηκε.'
        doneHint = 'Αν το Outlook αρνηθεί να στείλει κάποιο ως πολύ μεγάλο, βάλτε 35 MB στις Επιλογές και τρέξτε ξανά.'
        optLanguage = 'Γλώσσα'
        optMaxSize = 'Μέγιστο μέγεθος ανά e-mail'
        mb = 'MB'
        optPartLength = 'Διάρκεια μέρους'
        minutes = 'λεπτά'
        optQuality = 'Ποιότητα'
        qualityBest = 'Καλύτερη ποιότητα (πιο αργό)'
        qualityBalanced = 'Ισορροπημένη'
        qualityFast = 'Το πιο γρήγορο'
        optGreeting = 'Χαιρετισμός'
        optSendTo = 'Αποστολή πρόχειρων σε (προαιρετικό)'
        optAutoDrafts = 'Αυτόματη δημιουργία πρόχειρων Outlook'
        optSaveIn = 'Αποθήκευση μερών σε'
        ok = 'ΟΚ'
        tip = 'Συμβουλή: αν το Outlook αρνηθεί αρχείο 49 MB, επιλέξτε 35 MB (η κωδικοποίηση του e-mail προσθέτει περίπου ένα τρίτο).'
        stagePreparing = 'προετοιμασία'
        stageStarting = 'έναρξη'
        stageOptimising = 'βελτιστοποίηση'
        stageEncoding = 'κωδικοποίηση'
        stageDone = 'έτοιμο'
        partOf = 'Μέρος {0} από {1}'
        wordPart = 'Μέρος'
        speedTemplate = ' - ταχύτητα {0:0.0}x'
        etaSoon = 'λιγότερο από ένα λεπτό'
        etaMinutes = 'περίπου {0} λεπτά'
        etaHours = 'περίπου {0} ώ {1} λεπτά'
        etaTemplate = ' - απομένουν {0}'
        logStarting = 'Εκκίνηση: {0} βίντεο, {1} MB ανά e-mail, μέρη {2} λεπτών, σίγαση={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'Αποθηκεύτηκε {0} - {1}'
        logReuse = 'Επαναχρησιμοποίηση υπάρχοντος μέρους: {0}'
        logRetry = 'Το μέρος {0} βγήκε πολύ μεγάλο· νέα προσπάθεια στα {1} kbps.'
        logTooLargeWarn = 'Προειδοποίηση: το {0} είναι ακόμα {1} MB (στόχος {2} MB).'
        logOutlookFailed = 'Η αυτοματοποίηση του Outlook απέτυχε: {0}'
        logCancelledByUser = 'Ακυρώθηκε από τον χρήστη.'
        greetingDefault = 'Γεια σας,'
        subjPart = '{0} - μέρος {1} από {2}'
        subjRange = '{0} - μέρη {1}-{2} από {3}'
        subjMultiPart = 'Μέρος βίντεο {0}'
        subjMultiRange = 'Μέρη βίντεο {0}-{1}'
        aboutOneMinute = 'περίπου 1 λεπτό'
        aboutMinutes = 'περίπου {0} λεπτά'
        bodyAttached = 'Συνημμένο είναι το "{0}" ({1}).'
        bodyPart = 'Ακολουθεί το μέρος {0} από {1} του "{2}" ({3}).'
        bodyRange = 'Ακολουθούν τα μέρη {0}-{1} του "{2}" ({3} μέρη συνολικά, {4} το καθένα).'
        bodyMulti = 'Ακολουθούν {0} μέρη βίντεο.'
        attachedFiles = 'Συνημμένα αρχεία:'
        errNotFound = 'Το αρχείο δεν βρέθηκε: {0}'
        errNotVideo = 'Το αρχείο δεν μπόρεσε να διαβαστεί ως βίντεο: {0}'
        errNoVideoTrack = 'Δεν βρέθηκε ροή βίντεο στο: {0}'
        errNoFrameSize = 'Δεν μπόρεσε να διαβαστεί το μέγεθος καρέ του: {0}'
        errTooSmall = 'Τα {0} MB είναι πολύ λίγα για μέρος {1} λεπτών. Αυξήστε το μέγεθος ανά e-mail ή κοντύνετε τα μέρη.'
        errShortPart = 'Η διάρκεια του μέρους πρέπει να είναι τουλάχιστον μερικά δευτερόλεπτα.'
        errEncoder = 'Ο κωδικοποιητής βίντεο απέτυχε. {0}'
        errNoFfmpeg = 'Λείπει το ffmpeg.exe. Κρατήστε το στον ίδιο φάκελο με το VideoMail.ps1.'
        errNoFfmpeg2 = 'Κρατήστε τα VideoMail.ps1 και ffmpeg.exe μαζί στον ίδιο φάκελο.'
        errNoInputs = 'Δεν προστέθηκαν βίντεο.'
        errNothing = 'Δεν υπάρχει κάτι προς κωδικοποίηση.'
        errFatal1 = 'Το VideoMail δεν ξεκίνησε:'
        errFatal2 = 'Λεπτομέρειες: '
        cliInput = 'Είσοδος: {0} - {1}, {2}x{3}'
        cliDone = 'Ολοκληρώθηκε: {0} μέρη στο {1} ({2:0.0} λεπτά)'
        cliOutlook = 'Δημιουργήθηκαν {0} πρόχειρα Outlook.'
        cliEml = '{0} έτοιμα αρχεία e-mail (.eml): {1}'
        cliPartial = 'Δημιουργήθηκαν {0} πρόχειρα, μετά: {1}'
        cliCancelled = 'Ακυρώθηκε.'
    }
    ar = @{
        Rtl = $true; Native = 'العربية'
        optError = 'تعذّر فتح الخيارات:'
        windowTitle = 'VideoMail - فيديوهات طويلة عبر البريد'
        subtitle = 'أدخِل الفيديوهات الطويلة، واحصل على أجزاء بحجم البريد ومسودات جاهزة للإرسال.'
        options = 'الخيارات'
        dragHere = 'اسحب الفيديوهات إلى هنا'
        dropHint = 'أو انقر لاختيار الملفات (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'الفيديو'; colLength = 'المدة'; colSize = 'الحجم'; colParts = 'الأجزاء'
        removeFromList = 'إزالة من القائمة'
        summaryIdle = 'ألقِ فيديو في الأعلى، ثم اضغط الزر الأخضر.'
        summaryTemplate = '{0}، المدة {1} - {2}'
        videosCount = '{0} فيديو'
        emailParts = 'حوالي {0} جزءًا بالبريد'
        ready = 'جاهز.'
        readyGo = 'جاهز. اضغط الزر الأخضر عندما تكون مستعدًا.'
        go = 'تقسيم وتجهيز البريد'
        mute = 'إزالة الصوت (كتم)'
        cancel = 'إلغاء'
        cancelling = 'جارٍ الإلغاء...'
        cancelledStatus = 'أُلغي.'
        cancelledMsg = 'أُلغي. حُذفت الملفات الجزئية.'
        doneStatus = 'تم.'
        somethingWrong = 'حدث خطأ ما:'
        dropFirst = 'ألقِ فيديو أولًا، أو انقر المنطقة الزرقاء لاختيار واحد.'
        chooseVideos = 'اختيار الفيديوهات'
        filterVideos = 'الفيديوهات'; filterAll = 'كل الملفات'
        reading = 'قراءة {0}...'
        noVideosFound = 'لم يتم العثور على ملفات فيديو في:'
        couldNotRead = 'تعذّرت قراءة:'
        cannotWrite1 = 'لا يمكن الكتابة إلى:'
        cannotWrite2 = 'اختر مجلدًا آخر من الخيارات.'
        workingClose = 'لا يزال العمل جاريًا. إيقافه وإغلاق VideoMail؟'
        creatingDrafts = 'إنشاء مسودات Outlook...'
        creatingDraftsCount = 'إنشاء مسودات Outlook... ({0} من {1})'
        creatingEmailsCount = 'إنشاء رسائل جاهزة للإرسال... ({0} من {1})'
        doneBox1 = 'تم!'
        donePartsSaved = 'تم حفظ {0} من الأجزاء في:'
        doneOutlook1 = '{0} من المسودات تنتظرك في مسودات Outlook.'
        doneOutlook2 = 'افتح Outlook وراجعها ثم اضغط «إرسال» في كل واحدة.'
        donePartial1 = 'تم إنشاء {0} من المسودات، لكن Outlook أبلغ بعدها: {1}'
        donePartial2 = 'راجع مجلد المسودات ثم أعد التشغيل لبقية الأجزاء.'
        doneEml1 = 'خاصية Outlook التلقائية غير متاحة على هذا الجهاز، لذا حُفظ {0} من ملفات البريد الجاهزة في:'
        doneEml2 = 'افتح واحدًا وانقر «إعادة توجيه» وأضف المستلم ثم اضغط «إرسال».'
        doneNoDrafts = 'تم تخطي إنشاء المسودات.'
        doneHint = 'إذا رفض Outlook الإرسال بسبب الحجم، اضبط 35 MB في الخيارات وأعد التشغيل.'
        optLanguage = 'اللغة'
        optMaxSize = 'الحجم الأقصى لكل رسالة'
        mb = 'MB'
        optPartLength = 'مدة الجزء'
        minutes = 'دقائق'
        optQuality = 'الجودة'
        qualityBest = 'أفضل جودة (أبطأ)'
        qualityBalanced = 'متوازن'
        qualityFast = 'الأسرع'
        optGreeting = 'التحية'
        optSendTo = 'إرسال المسودات إلى (اختياري)'
        optAutoDrafts = 'إنشاء مسودات Outlook تلقائيًا'
        optSaveIn = 'حفظ الأجزاء في'
        ok = 'موافق'
        tip = 'نصيحة: إذا رفض Outlook ملفًا بحجم 49 MB فاختر 35 MB (ترميز البريد يضيف نحو الثلث).'
        stagePreparing = 'تحضير'
        stageStarting = 'بدء'
        stageOptimising = 'تحسين'
        stageEncoding = 'ترميز'
        stageDone = 'تم'
        partOf = 'الجزء {0} من {1}'
        wordPart = 'الجزء'
        speedTemplate = ' - سرعة {0:0.0}x'
        etaSoon = 'أقل من دقيقة'
        etaMinutes = 'حوالي {0} دقيقة'
        etaHours = 'حوالي {0} س {1} د'
        etaTemplate = ' - {0} متبقية'
        logStarting = 'البداية: {0} فيديو، {1} MB لكل رسالة، أجزاء {2} دقيقة، كتم={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'حُفظ {0} - {1}'
        logReuse = 'إعادة استخدام جزء موجود: {0}'
        logRetry = 'خرج الجزء {0} أكبر من المطلوب؛ إعادة المحاولة عند {1} kbps.'
        logTooLargeWarn = 'تحذير: {0} لا يزال {1} MB (الهدف {2} MB).'
        logOutlookFailed = 'فشل تشغيل Outlook: {0}'
        logCancelledByUser = 'ألغاه المستخدم.'
        greetingDefault = 'مرحبًا،'
        subjPart = '{0} - الجزء {1} من {2}'
        subjRange = '{0} - الأجزاء {1}-{2} من {3}'
        subjMultiPart = 'جزء فيديو {0}'
        subjMultiRange = 'أجزاء فيديو {0}-{1}'
        aboutOneMinute = 'حوالي دقيقة واحدة'
        aboutMinutes = 'حوالي {0} دقائق'
        bodyAttached = 'المرفق "{0}" ({1}).'
        bodyPart = 'هذا هو الجزء {0} من {1} من "{2}" ({3}).'
        bodyRange = 'هذه هي الأجزاء {0}-{1} من "{2}" ({3} أجزاء في المجموع، {4} لكل جزء).'
        bodyMulti = 'في الأسفل {0} من أجزاء الفيديو.'
        attachedFiles = 'الملفات المرفقة:'
        errNotFound = 'الملف غير موجود: {0}'
        errNotVideo = 'تعذّرت قراءة هذا الملف كفيديو: {0}'
        errNoVideoTrack = 'لا يوجد مسار فيديو في: {0}'
        errNoFrameSize = 'تعذّرت قراءة أبعاد الإطار لـ: {0}'
        errTooSmall = '{0} MB أصغر من اللازم لجزء مدته {1} دقيقة. ارفع الحجم لكل رسالة أو قصّر الأجزاء.'
        errShortPart = 'يجب أن تكون مدة الجزء بضع ثوانٍ على الأقل.'
        errEncoder = 'فشل مرمّز الفيديو. {0}'
        errNoFfmpeg = 'ffmpeg.exe غير موجود. أبقِه في نفس مجلد VideoMail.ps1.'
        errNoFfmpeg2 = 'أبقِ VideoMail.ps1 و ffmpeg.exe معًا في نفس المجلد.'
        errNoInputs = 'لم تُضف أي فيديوهات.'
        errNothing = 'لا يوجد ما يمكن ترميزه.'
        errFatal1 = 'تعذّر تشغيل VideoMail:'
        errFatal2 = 'التفاصيل: '
        cliInput = 'الإدخال: {0} - {1}، {2}x{3}'
        cliDone = 'اكتمل: {0} جزء في {1} ({2:0.0} دقيقة)'
        cliOutlook = 'تم إنشاء {0} مسودة Outlook.'
        cliEml = '{0} ملف بريد جاهز (.eml): {1}'
        cliPartial = 'تم إنشاء {0} مسودة، ثم: {1}'
        cliCancelled = 'أُلغي.'
    }
    fa = @{
        Rtl = $true; Native = 'فارسی'
        optError = 'باز شدن گزینه‌ها ممکن نشد:'
        windowTitle = 'VideoMail - ویدیوهای طولانی با ایمیل'
        subtitle = 'ویدیوی طولانی بدهید؛ بخش‌های مناسب ایمیل و پیش‌نویس‌های آماده ارسال بگیرید.'
        options = 'گزینه‌ها'
        dragHere = 'ویدیوها را اینجا بکشید'
        dropHint = 'یا برای انتخاب فایل‌ها کلیک کنید (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'ویدیو'; colLength = 'مدت'; colSize = 'حجم'; colParts = 'بخش‌ها'
        removeFromList = 'حذف از فهرست'
        summaryIdle = 'یک ویدیو در بالا بیندازید، بعد دکمه سبز را بزنید.'
        summaryTemplate = '{0}، مدت {1} - {2}'
        videosCount = '{0} ویدیو'
        emailParts = 'حدود {0} بخش ایمیل'
        ready = 'آماده.'
        readyGo = 'آماده. هر وقت راحت بودید دکمه سبز را بزنید.'
        go = 'تقسیم و آماده‌سازی ایمیل'
        mute = 'حذف صدا (بی‌صدا)'
        cancel = 'لغو'
        cancelling = 'در حال لغو...'
        cancelledStatus = 'لغو شد.'
        cancelledMsg = 'لغو شد. فایل‌های نیمه‌تمام حذف شدند.'
        doneStatus = 'تمام شد.'
        somethingWrong = 'مشکلی پیش آمد:'
        dropFirst = 'اول یک ویدیو بیندازید، یا روی ناحیه آبی کلیک کنید.'
        chooseVideos = 'انتخاب ویدیوها'
        filterVideos = 'ویدیوها'; filterAll = 'همه فایل‌ها'
        reading = 'خواندن {0}...'
        noVideosFound = 'فایل ویدیویی پیدا نشد در:'
        couldNotRead = 'خواندن ممکن نشد:'
        cannotWrite1 = 'نوشتن در این مسیر ممکن نیست:'
        cannotWrite2 = 'از گزینه‌ها پوشه دیگری انتخاب کنید.'
        workingClose = 'کار هنوز در جریان است. متوقف و بسته شود؟'
        creatingDrafts = 'ساخت پیش‌نویس‌های Outlook...'
        creatingDraftsCount = 'ساخت پیش‌نویس‌های Outlook... ({0} از {1})'
        creatingEmailsCount = 'ساخت ایمیل‌های آماده ارسال... ({0} از {1})'
        doneBox1 = 'تمام شد!'
        donePartsSaved = '{0} بخش در این مسیر ذخیره شد:'
        doneOutlook1 = '{0} پیش‌نویس در پیش‌نویس‌های Outlook منتظر شماست.'
        doneOutlook2 = 'Outlook را باز کنید، بررسی کنید و هر یکی را «ارسال» بزنید.'
        donePartial1 = '{0} پیش‌نویس ساخته شد، اما Outlook بعدش گفت: {1}'
        donePartial2 = 'پوشه پیش‌نویس‌ها را ببینید و برای بقیه دوباره اجرا کنید.'
        doneEml1 = 'اتوماسیون Outlook روی این رایانه در دسترس نیست، بنابراین {0} فایل ایمیل آماده ارسال ذخیره شد در:'
        doneEml2 = 'یکی را باز کنید، «Forward» را بزنید، گیرنده را اضافه کنید و ارسال کنید.'
        doneNoDrafts = 'ساخت پیش‌نویس‌ها انجام نشد.'
        doneHint = 'اگر Outlook به‌خاطر حجم رد کرد، در گزینه‌ها 35 MB بگذارید و دوباره اجرا کنید.'
        optLanguage = 'زبان'
        optMaxSize = 'حداکثر حجم هر ایمیل'
        mb = 'MB'
        optPartLength = 'مدت هر بخش'
        minutes = 'دقیقه'
        optQuality = 'کیفیت'
        qualityBest = 'بهترین کیفیت (کندتر)'
        qualityBalanced = 'متعادل'
        qualityFast = 'سریع‌ترین'
        optGreeting = 'احوال‌پرسی'
        optSendTo = 'ارسال پیش‌نویس‌ها به (اختیاری)'
        optAutoDrafts = 'ساخت خودکار پیش‌نویس‌های Outlook'
        optSaveIn = 'ذخیره بخش‌ها در'
        ok = 'تأیید'
        tip = 'نکته: اگر Outlook فایل 49 MB را نپذیرفت، 35 MB را انتخاب کنید (کدگذاری ایمیل حدود یک‌سوم حجم اضافه می‌کند).'
        stagePreparing = 'آماده‌سازی'
        stageStarting = 'شروع'
        stageOptimising = 'بهینه‌سازی'
        stageEncoding = 'رمزگذاری'
        stageDone = 'انجام شد'
        partOf = 'بخش {0} از {1}'
        wordPart = 'بخش'
        speedTemplate = ' - سرعت {0:0.0}x'
        etaSoon = 'کمتر از یک دقیقه'
        etaMinutes = 'حدود {0} دقیقه'
        etaHours = 'حدود {0} ساعت و {1} دقیقه'
        etaTemplate = ' - {0} باقی'
        logStarting = 'شروع: {0} ویدیو، {1} MB برای هر ایمیل، بخش‌های {2} دقیقه‌ای، بی‌صدا={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'ذخیره شد {0} - {1}'
        logReuse = 'استفاده دوباره از بخش موجود: {0}'
        logRetry = 'بخش {0} بزرگ‌تر از حد درآمد؛ تلاش دوباره با {1} kbps.'
        logTooLargeWarn = 'هشدار: {0} هنوز {1} MB است (هدف {2} MB).'
        logOutlookFailed = 'اتوماسیون Outlook ناموفق بود: {0}'
        logCancelledByUser = 'کاربر لغو کرد.'
        greetingDefault = 'سلام،'
        subjPart = '{0} - بخش {1} از {2}'
        subjRange = '{0} - بخش‌های {1} تا {2} از {3}'
        subjMultiPart = 'بخش ویدیویی {0}'
        subjMultiRange = 'بخش‌های ویدیویی {0}-{1}'
        aboutOneMinute = 'حدود یک دقیقه'
        aboutMinutes = 'حدود {0} دقیقه'
        bodyAttached = 'فایل «{0}» ({1}) پیوست است.'
        bodyPart = 'این بخش {0} از {1} از «{2}» است ({3}).'
        bodyRange = 'این‌ها بخش‌های {0} تا {1} از «{2}» هستند ({3} بخش در کل، هر کدام {4}).'
        bodyMulti = 'در زیر {0} بخش ویدیویی آمده است.'
        attachedFiles = 'فایل‌های پیوست:'
        errNotFound = 'فایل پیدا نشد: {0}'
        errNotVideo = 'این فایل به‌عنوان ویدیو خوانده نشد: {0}'
        errNoVideoTrack = 'مسیر ویدیویی در این فایل نیست: {0}'
        errNoFrameSize = 'اندازه فریم خوانده نشد: {0}'
        errTooSmall = '{0} MB برای بخش {1} دقیقه‌ای خیلی کم است. حجم هر ایمیل را بیشتر یا بخش‌ها را کوتاه‌تر کنید.'
        errShortPart = 'مدت بخش باید دست‌کم چند ثانیه باشد.'
        errEncoder = 'رمزگذار ویدیو خطا داد. {0}'
        errNoFfmpeg = 'ffmpeg.exe پیدا نشد. آن را در همان پوشه VideoMail.ps1 نگه دارید.'
        errNoFfmpeg2 = 'VideoMail.ps1 و ffmpeg.exe را در یک پوشه نگه دارید.'
        errNoInputs = 'هیچ ویدیویی اضافه نشد.'
        errNothing = 'چیزی برای رمزگذاری نیست.'
        errFatal1 = 'VideoMail اجرا نشد:'
        errFatal2 = 'جزئیات: '
        cliInput = 'ورودی: {0} - {1}، {2}x{3}'
        cliDone = 'انجام شد: {0} بخش در {1} ({2:0.0} دقیقه)'
        cliOutlook = '{0} پیش‌نویس Outlook ساخته شد.'
        cliEml = '{0} فایل ایمیل آماده (.eml): {1}'
        cliPartial = '{0} پیش‌نویس ساخته شد، سپس: {1}'
        cliCancelled = 'لغو شد.'
    }
    he = @{
        Rtl = $true; Native = 'עברית'
        optError = 'לא ניתן לפתוח את האפשרויות:'
        windowTitle = 'VideoMail - סרטונים ארוכים באימייל'
        subtitle = 'סרטונים ארוכים נכנסים. חלקים בגודל אימייל וטיוטות מוכנות לשליחה יוצאים.'
        options = 'אפשרויות'
        dragHere = 'גררו סרטונים לכאן'
        dropHint = 'או לחצו כדי לבחור קבצים (MP4, MOV, MKV, AVI, WMV, MTS...)'
        colVideo = 'סרטון'; colLength = 'אורך'; colSize = 'גודל'; colParts = 'חלקים'
        removeFromList = 'הסרה מהרשימה'
        summaryIdle = 'גררו סרטון למעלה ואז לחצו על הכפתור הירוק.'
        summaryTemplate = '{0}, אורך כולל {1} - {2}'
        videosCount = '{0} סרטונים'
        emailParts = 'כ-{0} חלקי אימייל'
        ready = 'מוכן.'
        readyGo = 'מוכן. לחצו על הכפתור הירוק כשאתם מוכנים.'
        go = 'פיצול והכנת אימיילים'
        mute = 'הסרת שמע (השתקה)'
        cancel = 'ביטול'
        cancelling = 'מבטל...'
        cancelledStatus = 'בוטל.'
        cancelledMsg = 'בוטל. קבצים חלקיים נמחקו.'
        doneStatus = 'הסתיים.'
        somethingWrong = 'משהו השתבש:'
        dropFirst = 'קודם גררו סרטון, או לחצו על האזור הכחול כדי לבחור.'
        chooseVideos = 'בחירת סרטונים'
        filterVideos = 'סרטונים'; filterAll = 'כל הקבצים'
        reading = 'קורא {0}...'
        noVideosFound = 'לא נמצאו קובצי וידאו ב:'
        couldNotRead = 'הקריאה נכשלה:'
        cannotWrite1 = 'אין אפשרות לכתוב אל:'
        cannotWrite2 = 'בחרו תיקייה אחרת באפשרויות.'
        workingClose = 'עדיין מתבצעת עבודה. לעצור ולסגור את VideoMail?'
        creatingDrafts = 'יוצר טיוטות Outlook...'
        creatingDraftsCount = 'יוצר טיוטות Outlook... ({0} מתוך {1})'
        creatingEmailsCount = 'יוצר אימיילים מוכנים לשליחה... ({0} מתוך {1})'
        doneBox1 = 'הסתיים!'
        donePartsSaved = '{0} חלקים נשמרו ב:'
        doneOutlook1 = '{0} טיוטות ממתינות בטיוטות של Outlook.'
        doneOutlook2 = 'פתחו את Outlook, בדקו ולחצו Send בכל אחת.'
        donePartial1 = '{0} טיוטות נוצרו, אך Outlook דיווח אחר כך: {1}'
        donePartial2 = 'בדקו את תיקיית הטיוטות והריצו שוב לשאר.'
        doneEml1 = 'אוטומציה של Outlook אינה זמינה במחשב זה, לכן {0} קובצי אימייל מוכנים נשמרו ב:'
        doneEml2 = 'פתחו אחד, לחצו Forward, הוסיפו נמען ולחצו Send.'
        doneNoDrafts = 'יצירת הטיוטות דולגה.'
        doneHint = 'אם Outlook מסרב לשלוח בגלל הגודל, קבעו 35 MB באפשרויות והריצו שוב.'
        optLanguage = 'שפה'
        optMaxSize = 'גודל מקסימלי לאימייל'
        mb = 'MB'
        optPartLength = 'אורך חלק'
        minutes = 'דקות'
        optQuality = 'איכות'
        qualityBest = 'איכות מיטבית (אטי יותר)'
        qualityBalanced = 'מאוזן'
        qualityFast = 'המהיר ביותר'
        optGreeting = 'ברכה'
        optSendTo = 'שליחת הטיוטות אל (רשות)'
        optAutoDrafts = 'ליצור טיוטות Outlook אוטומטית'
        optSaveIn = 'שמירת החלקים ב'
        ok = 'אישור'
        tip = 'טיפ: אם Outlook מסרב לשלוח קובץ של 49 MB, בחרו 35 MB (קידוד האימייל מוסיף כשליש).'
        stagePreparing = 'מכין'
        stageStarting = 'מתחיל'
        stageOptimising = 'מייעל'
        stageEncoding = 'מקודד'
        stageDone = 'הסתיים'
        partOf = 'חלק {0} מתוך {1}'
        wordPart = 'חלק'
        speedTemplate = ' - מהירות {0:0.0}x'
        etaSoon = 'פחות מדקה'
        etaMinutes = 'נותרו כ-{0} דקות'
        etaHours = 'נותרו כ-{0} שע׳ {1} דק׳'
        etaTemplate = ' - {0}'
        logStarting = 'מתחיל: {0} סרטונים, {1} MB לאימייל, חלקים של {2} דקות, השתקה={3}'
        logPart = '{0} {1}/{2}: {3}'
        logSaved = 'נשמר {0} - {1}'
        logReuse = 'משתמש שוב בחלק קיים: {0}'
        logRetry = 'חלק {0} יצא גדול מדי; מנסה שוב ב-{1} kbps.'
        logTooLargeWarn = 'אזהרה: {0} עדיין {1} MB (יעד {2} MB).'
        logOutlookFailed = 'אוטומציה של Outlook נכשלה: {0}'
        logCancelledByUser = 'בוטל על ידי המשתמש.'
        greetingDefault = 'שלום,'
        subjPart = '{0} - חלק {1} מתוך {2}'
        subjRange = '{0} - חלקים {1}-{2} מתוך {3}'
        subjMultiPart = 'חלק וידאו {0}'
        subjMultiRange = 'חלקי וידאו {0}-{1}'
        aboutOneMinute = 'כדקה'
        aboutMinutes = 'כ-{0} דקות'
        bodyAttached = 'מצורף "{0}" ({1}).'
        bodyPart = 'הנה חלק {0} מתוך {1} של "{2}" ({3}).'
        bodyRange = 'הנה חלקים {0}-{1} של "{2}" ({3} חלקים בסך הכל, {4} כל אחד).'
        bodyMulti = 'להלן {0} חלקי וידאו.'
        attachedFiles = 'קבצים מצורפים:'
        errNotFound = 'הקובץ לא נמצא: {0}'
        errNotVideo = 'לא ניתן לקרוא את הקובץ כווידאו: {0}'
        errNoVideoTrack = 'אין ערוץ וידאו ב: {0}'
        errNoFrameSize = 'לא ניתן לקרוא את גודל הפריים של: {0}'
        errTooSmall = '{0} MB קטן מדי לחלק של {1} דקות. הגדילו את הגודל לאימייל או קצרו את החלקים.'
        errShortPart = 'אורך החלק חייב להיות לפחות כמה שניות.'
        errEncoder = 'מקודד הווידאו נכשל. {0}'
        errNoFfmpeg = 'ffmpeg.exe חסר. השאירו אותו באותה תיקייה כמו VideoMail.ps1.'
        errNoFfmpeg2 = 'השאירו את VideoMail.ps1 ו-ffmpeg.exe יחד באותה תיקייה.'
        errNoInputs = 'לא נוספו סרטונים.'
        errNothing = 'אין מה לקודד.'
        errFatal1 = 'VideoMail לא הצליח להיפתח:'
        errFatal2 = 'פרטים: '
        cliInput = 'קלט: {0} - {1}, {2}x{3}'
        cliDone = 'הסתיים: {0} חלקים ב-{1} ({2:0.0} דקות)'
        cliOutlook = 'נוצרו {0} טיוטות Outlook.'
        cliEml = '{0} קובצי אימייל מוכנים לשליחה (.eml): {1}'
        cliPartial = 'נוצרו {0} טיוטות, ואז: {1}'
        cliCancelled = 'בוטל.'
    }
}

function Get-Str {
    param([string]$Key)
    if ($script:Lang -and $script:Lang.ContainsKey($Key)) { return [string]$script:Lang[$Key] }
    if ($script:LangTable.en.ContainsKey($Key)) { return [string]$script:LangTable.en[$Key] }
    return $Key
}

function Protect-LtrRuns {
    # In right-to-left text the bidi algorithm splits mixed runs like
    # "1.90 GB" or "2026.mp4" and reverses the pieces. Wrapping each
    # numbers/filename run in Unicode isolates keeps it intact on screen.
    param([string]$Text)
    if (-not $script:Lang.Rtl) { return $Text }
    $lri = [string][char]0x2066
    $pdi = [string][char]0x2069
    $pattern = '\d+(?::\d{2})+(?:\.\d+)?|\d+(?:\.\d+)*(?:\.[A-Za-z0-9]+)?(?:\s?[A-Za-z]{1,4})?[x%]?'
    return [regex]::Replace($Text, $pattern, ($lri + '$&' + $pdi))
}

function Test-LanguageCode {
    param([string]$Code)
    return ($Code -and $script:LangTable.ContainsKey($Code))
}

function Get-WindowsLanguage {
    try {
        $code = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        if ($script:LangTable.ContainsKey($code)) { return $code }
    } catch { }
    return 'en'
}

function Set-AppLanguage {
    param([string]$Code)
    if (-not (Test-LanguageCode $Code)) { $Code = 'en' }
    $script:LangCode = $Code
    $script:Lang = $script:LangTable[$Code]
}

function Get-SettingPaths {
    # The app folder comes first so a USB stick keeps its own setting; when it
    # is not writable, %APPDATA% is used instead.
    $paths = @(Join-Path $script:AppDir 'VideoMail.settings.txt')
    if ($env:APPDATA) { $paths += (Join-Path $env:APPDATA 'VideoMail\settings.txt') }
    return $paths
}

function Read-AppSetting {
    param([string]$Key, [string[]]$Paths)
    if (-not $Paths) { $Paths = Get-SettingPaths }
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) {
            try {
                foreach ($line in [IO.File]::ReadAllLines($p)) {
                    $m = [regex]::Match($line, ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*$'))
                    if ($m.Success) { return $m.Groups[1].Value }
                }
            } catch { }
        }
    }
    return ''
}

function Write-AppSetting {
    param([string]$Key, [string]$Value, [string]$Path)
    $explicit = [bool]$Path
    if (-not $Path) { $Path = (Get-SettingPaths)[0] }
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lines = @()
        if (Test-Path -LiteralPath $Path) { $lines = [IO.File]::ReadAllLines($Path) }
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
                $lines[$i] = "$Key=$Value"
                $found = $true
            }
        }
        if (-not $found) { $lines += "$Key=$Value" }
        [IO.File]::WriteAllLines($Path, $lines)
        return $true
    } catch { }
    # App folder was not writable; fall back to %APPDATA%.
    if ($env:APPDATA -and -not $explicit) {
        try {
            $roaming = Join-Path $env:APPDATA 'VideoMail'
            if (-not (Test-Path -LiteralPath $roaming)) { New-Item -ItemType Directory -Path $roaming -Force | Out-Null }
            $p2 = Join-Path $roaming 'settings.txt'
            $lines = @()
            if (Test-Path -LiteralPath $p2) { $lines = [IO.File]::ReadAllLines($p2) }
            $found = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
                    $lines[$i] = "$Key=$Value"
                    $found = $true
                }
            }
            if (-not $found) { $lines += "$Key=$Value" }
            [IO.File]::WriteAllLines($p2, $lines)
            return $true
        } catch { }
    }
    return $false
}

function Resolve-AppLanguage {
    # Explicit -Language wins; then the saved choice; then the Windows language.
    if (Test-LanguageCode $Language) { return $Language }
    $saved = Read-AppSetting 'language'
    if (Test-LanguageCode $saved) { return $saved }
    return Get-WindowsLanguage
}

Set-AppLanguage (Resolve-AppLanguage)

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

    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 250
            if ($script:HasGui) {
                try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            }
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
            -Mute $Mute -Width $Media.Width -Height $Media.Height -Fps $Media.Fps

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

function Test-ExistingPart {
    param([pscustomobject]$Job)
    if (-not (Test-Path -LiteralPath $Job.Output)) { return $false }
    $size = (Get-Item -LiteralPath $Job.Output).Length
    return ($size -ge ($Job.Plan.TargetBytes * 0.40) -and $size -le ($Job.Plan.TargetBytes * 1.01))
}

function Invoke-EncodeJob {
    param(
        [pscustomobject]$Job,
        [string]$Preset,
        [string]$TempDir
    )

    if (Test-ExistingPart -Job $Job) {
        Write-AppLog ((Get-Str 'logReuse') -f $Job.FileName)
        return
    }

    $plan = $Job.Plan
    $partial = $Job.Output + '.part'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }

    $passLog = Join-Path $TempDir ('pass_' + [guid]::NewGuid().ToString('N'))
    $progress = Join-Path $TempDir 'progress.txt'
    $nullDev = Get-NullDevice

    $common = @(
        '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
        '-ss', (Format-Seconds $Job.Start),
        '-t', (Format-Seconds $Job.Duration),
        '-i', $Job.Source
    )

    # Pass 1: analysis only.
    $args1 = $common + @(
        '-map', '0:v:0', '-an', '-vf', $plan.VideoFilter,
        '-c:v', 'libx264', '-preset', $Preset, '-profile:v', 'high', '-level', '4.0',
        '-pix_fmt', 'yuv420p', '-b:v', ("{0}k" -f $plan.VideoKbps),
        '-pass', '1', '-passlogfile', $passLog,
        '-progress', $progress, '-nostats', '-f', 'null', $nullDev
    )

    $script:CurPassStart = 0.0
    $script:CurPassLen = 0.45
    Invoke-FFmpeg -Arguments $args1 -ProgressFile $progress -ExpectedSeconds $Job.Duration -OnTick {
        param($frac, $speed, $elapsed)
        Update-OverallProgress -Fraction $frac -Speed $speed -Elapsed $elapsed -Stage (Get-Str 'stageOptimising')
    }

    $args2 = $common + @('-map', '0:v:0')
    if ($plan.AudioKbps -gt 0) {
        $channels = if ($Job.Channels -eq 1) { '1' } else { '2' }
        $args2 += @(
            '-map', '0:a:0?', '-c:a', 'aac', '-b:a', ("{0}k" -f $plan.AudioKbps),
            '-ac', $channels, '-ar', '48000'
        )
    } else {
        $args2 += @('-an')
    }
    $args2 += @(
        '-vf', $plan.VideoFilter,
        '-c:v', 'libx264', '-preset', $Preset, '-profile:v', 'high', '-level', '4.0',
        '-pix_fmt', 'yuv420p', '-b:v', ("{0}k" -f $plan.VideoKbps),
        '-pass', '2', '-passlogfile', $passLog,
        '-map_metadata', '-1', '-movflags', '+faststart',
        '-progress', $progress, '-nostats', '-f', 'mp4', $partial
    )

    $attempt = 0
    while ($true) {
        $attempt++
        $script:CurPassStart = 0.45
        $script:CurPassLen = 0.55
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

        # Only pass 2 needs to run again; the pass-1 analysis is still valid.
        $factor = ($plan.TargetBytes * 0.97) / $size
        $newKbps = [int][math]::Floor($plan.VideoKbps * $factor)
        if ($newKbps -lt 80) { $newKbps = 80 }
        Write-AppLog ((Get-Str 'logRetry') -f $Job.PartNumber, $newKbps)
        $plan.VideoKbps = $newKbps
        $idx = [array]::IndexOf($args2, '-b:v')
        if ($idx -ge 0) { $args2[$idx + 1] = ("{0}k" -f $newKbps) }
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    Move-Item -LiteralPath $partial -Destination $Job.Output -Force
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
    $etaText = ''
    $totalElapsed = $Elapsed
    if ($script:JobClock) { $totalElapsed = $script:JobClock.Elapsed.TotalSeconds }
    if ($overall -gt 0.02 -and $totalElapsed -gt 3) {
        $eta = ($totalElapsed / $overall) - $totalElapsed
        if ($eta -gt 0) { $etaText = ((Get-Str 'etaTemplate') -f (Format-Eta $eta)) }
    }

    $part = [math]::Min($script:CurPartIndex + 1, $script:TotalParts)
    $pct = [int][math]::Round($Fraction * 100)
    $text = (Protect-LtrRuns (((Get-Str 'partOf') -f $part, $script:TotalParts) + " - $Stage $pct%$speedText$etaText"))

    if ($script:HasGui) {
        try {
            $script:UiProgress.Value = [int][math]::Round($overall * 1000)
            $script:UiStatus.Text = $text
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

function Show-MsgBox {
    param([string]$Text, [string]$Title, $Buttons = 'OK', $Icon = 'Information')
    if ($script:Lang.Rtl) {
        return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
            ([System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign))
    }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Update-InputSummary {
    if (-not $script:HasGui) { return }
    $count = $script:Inputs.Count
    if ($count -eq 0) {
        $script:UiSummary.Text = (Get-Str 'summaryIdle')
        return
    }
    $totalSeconds = 0.0
    $parts = 0
    foreach ($m in $script:Inputs) {
        $totalSeconds += $m.Duration
        $parts += [int][math]::Ceiling($m.Duration / ($script:UiConfig.Minutes * 60.0))
    }
    $script:UiSummary.Text = (Protect-LtrRuns ((Get-Str 'summaryTemplate') -f `
        ((Get-Str 'videosCount') -f $count), (Format-Duration $totalSeconds), `
        ((Get-Str 'emailParts') -f $parts)))
}

function Update-ListFromInputs {
    if (-not $script:HasGui -or -not $script:UiList) { return }
    $script:UiList.BeginUpdate()
    try {
        $script:UiList.Items.Clear()
        foreach ($media in $script:Inputs) {
            $name = Split-Path -Leaf $media.Path
            if ($script:Lang.Rtl) {
                if ($name -match '^[\x20-\x7E]+$') {
                    $name = [string][char]0x2066 + $name + [string][char]0x2069
                } else {
                    $name = Protect-LtrRuns $name
                }
            }
            $row = New-Object System.Windows.Forms.ListViewItem($name)
            [void]$row.SubItems.Add((Protect-LtrRuns (Format-Duration $media.Duration)))
            [void]$row.SubItems.Add((Protect-LtrRuns (Format-MB $media.Size)))
            [void]$row.SubItems.Add((Protect-LtrRuns ('{0}' -f [int][math]::Ceiling($media.Duration / ($script:UiConfig.Minutes * 60.0)))))
            $row.Tag = $media.Path
            [void]$script:UiList.Items.Add($row)
        }
    } finally {
        $script:UiList.EndUpdate()
    }
}

function Add-VideoFiles {
    param([string[]]$Paths)
    if (-not $Paths -or $Paths.Count -eq 0) { return }

    # Accept dropped folders too: take the video files directly inside them.
    $mediaExt = '^\.(mp4|mov|m4v|mkv|webm|avi|wmv|asf|flv|ts|mts|m2ts|mpg|mpeg|3gp|3g2)$'
    $queue = New-Object System.Collections.ArrayList
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $found = @(Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match $mediaExt } | Sort-Object Name)
            if ($found.Count -eq 0) {
                [void](Show-MsgBox ((Get-Str 'noVideosFound') + "`r`n$p") 'VideoMail' 'OK' 'Information')
                continue
            }
            foreach ($f in $found) { [void]$queue.Add($f.FullName) }
        } else {
            [void]$queue.Add($p)
        }
    }

    $added = 0
    foreach ($path in $queue) {
        $full = ''
        try { $full = (Resolve-Path -LiteralPath $path).Path } catch { continue }
        if (@($script:Inputs | Where-Object { $_.Path -eq $full }).Count -gt 0) { continue }

        try {
            $script:UiStatus.Text = (Get-Str 'reading') -f (Split-Path -Leaf $full)
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            $media = Get-MediaInfo -VideoPath $full
            [void]$script:Inputs.Add($media)
            $added++
        } catch {
            [void](Show-MsgBox ((Get-Str 'couldNotRead') + "`r`n`r`n$full`r`n`r`n" + $_.Exception.Message) 'VideoMail' 'OK' 'Warning')
        }
    }

    if ($added -gt 0 -and -not $script:UiConfig.OutDir) {
        $first = $script:Inputs[0].Path
        $script:UiConfig.OutDir = Join-Path (Split-Path -Parent $first) 'VideoMail parts'
    }
    Update-ListFromInputs
    Update-InputSummary
    if ($added -gt 0) { $script:UiStatus.Text = (Get-Str 'readyGo') }
}

function Remove-SelectedVideos {
    if ($script:UiList.SelectedItems.Count -eq 0) { return }
    foreach ($item in @($script:UiList.SelectedItems)) {
        $script:UiList.Items.Remove($item)
        $match = @($script:Inputs | Where-Object { $_.Path -eq $item.Tag }) | Select-Object -First 1
        if ($match) { [void]$script:Inputs.Remove($match) }
    }
    Update-InputSummary
}

function Show-OpenVideoDialog {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = (Get-Str 'chooseVideos')
    $dlg.Filter = (Get-Str 'filterVideos') + '|*.mp4;*.mov;*.m4v;*.mkv;*.webm;*.avi;*.wmv;*.asf;*.flv;*.ts;*.mts;*.m2ts;*.mpg;*.mpeg;*.3gp;*.3g2|' +
        (Get-Str 'filterAll') + '|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        Add-VideoFiles -Paths $dlg.FileNames
    }
}

function Show-OptionsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = (Get-Str 'options')
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 470)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $dlg.BackColor = [System.Drawing.Color]::White
    if ($script:Lang.Rtl) {
        $dlg.RightToLeft = 'Yes'
        $dlg.RightToLeftLayout = $true
    }

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Fill'
    $grid.ColumnCount = 2
    $grid.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 8)
    $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 170))) | Out-Null
    $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    for ($i = 0; $i -lt 8; $i++) {
        $grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
    }

    $dlgRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $dlgRoot.Dock = 'Fill'
    $dlgRoot.ColumnCount = 1
    $dlgRoot.RowCount = 3
    $dlgRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $dlgRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
    $dlgRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52))) | Out-Null
    $dlg.Controls.Add($dlgRoot)
    $dlgRoot.Controls.Add($grid, 0, 0)

    function New-Label([string]$text, [int]$row) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Dock = 'Fill'
        $l.TextAlign = 'MiddleLeft'
        $grid.Controls.Add($l, 0, $row)
        return $l
    }

    New-Label (Get-Str 'optLanguage') 0 | Out-Null
    $langCombo = New-Object System.Windows.Forms.ComboBox
    $langCombo.DropDownStyle = 'DropDownList'
    $langCombo.Dock = 'Fill'
    foreach ($code in $script:LangCodes) {
        [void]$langCombo.Items.Add($script:LangTable[$code].Native)
    }
    $langCombo.SelectedIndex = [array]::IndexOf($script:LangCodes, $script:LangCode)
    if ($langCombo.SelectedIndex -lt 0) { $langCombo.SelectedIndex = 0 }
    $grid.Controls.Add($langCombo, 1, 0)

    New-Label (Get-Str 'optMaxSize') 1 | Out-Null
    $sizePanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $sizePanel.Dock = 'Fill'
    $size = New-Object System.Windows.Forms.NumericUpDown
    $size.Minimum = 5; $size.Maximum = 50
    $size.Value = [decimal][math]::Min(50, [math]::Max(5, $script:UiConfig.TargetMB))
    $size.Width = 70
    $mb = New-Object System.Windows.Forms.Label
    $mb.Text = (Get-Str 'mb'); $mb.AutoSize = $true; $mb.Margin = New-Object System.Windows.Forms.Padding(4, 8, 0, 0)
    $sizePanel.Controls.Add($size); $sizePanel.Controls.Add($mb)
    $grid.Controls.Add($sizePanel, 1, 1)

    New-Label (Get-Str 'optPartLength') 2 | Out-Null
    $lenPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $lenPanel.Dock = 'Fill'
    $len = New-Object System.Windows.Forms.NumericUpDown
    $len.Minimum = 1; $len.Maximum = 30
    $len.Value = [decimal][math]::Min(30, [math]::Max(1, $script:UiConfig.Minutes))
    $len.Width = 70
    $min = New-Object System.Windows.Forms.Label
    $min.Text = (Get-Str 'minutes'); $min.AutoSize = $true; $min.Margin = New-Object System.Windows.Forms.Padding(4, 8, 0, 0)
    $lenPanel.Controls.Add($len); $lenPanel.Controls.Add($min)
    $grid.Controls.Add($lenPanel, 1, 2)

    New-Label (Get-Str 'optQuality') 3 | Out-Null
    $quality = New-Object System.Windows.Forms.ComboBox
    $quality.DropDownStyle = 'DropDownList'
    $quality.Dock = 'Fill'
    [void]$quality.Items.Add((Get-Str 'qualityBest'))
    [void]$quality.Items.Add((Get-Str 'qualityBalanced'))
    [void]$quality.Items.Add((Get-Str 'qualityFast'))
    $quality.SelectedIndex = 0
    if ($script:UiConfig.Quality -eq 'balanced') { $quality.SelectedIndex = 1 }
    if ($script:UiConfig.Quality -eq 'fast') { $quality.SelectedIndex = 2 }
    $grid.Controls.Add($quality, 1, 3)

    New-Label (Get-Str 'optGreeting') 4 | Out-Null
    $greeting = New-Object System.Windows.Forms.TextBox
    $greeting.Dock = 'Fill'
    $greetingText = [string]$script:UiConfig.Greeting
    if (-not $greetingText.Trim()) { $greetingText = (Get-Str 'greetingDefault') }
    $greeting.Text = $greetingText
    $grid.Controls.Add($greeting, 1, 4)

    New-Label (Get-Str 'optSendTo') 5 | Out-Null
    $to = New-Object System.Windows.Forms.TextBox
    $to.Dock = 'Fill'
    $to.Text = $script:UiConfig.To
    $grid.Controls.Add($to, 1, 5)

    $drafts = New-Object System.Windows.Forms.CheckBox
    $drafts.Text = (Get-Str 'optAutoDrafts')
    $drafts.Checked = -not $script:UiConfig.NoDrafts
    $drafts.Dock = 'Fill'
    $grid.Controls.Add($drafts, 1, 6)

    New-Label (Get-Str 'optSaveIn') 7 | Out-Null
    $outPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $outPanel.Dock = 'Fill'
    $outPanel.ColumnCount = 2
    $outPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $outPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 42))) | Out-Null
    $outBox = New-Object System.Windows.Forms.TextBox
    $outBox.Dock = 'Fill'
    $outBox.Text = $script:UiConfig.OutDir
    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = '...'
    $browse.Dock = 'Fill'
    $browse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($outBox.Text) { $fb.SelectedPath = $outBox.Text }
        if ($fb.ShowDialog() -eq 'OK') { $outBox.Text = $fb.SelectedPath }
    })
    $outPanel.Controls.Add($outBox, 0, 0)
    $outPanel.Controls.Add($browse, 1, 0)
    $grid.Controls.Add($outPanel, 1, 7)

    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = (Get-Str 'tip')
    $tip.Dock = 'Fill'
    $tip.AutoSize = $false
    $tip.Padding = New-Object System.Windows.Forms.Padding(18, 4, 18, 0)
    $tip.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $tip.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $dlgRoot.Controls.Add($tip, 0, 1)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.Padding = New-Object System.Windows.Forms.Padding(0, 6, 16, 6)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = (Get-Str 'ok'); $ok.Width = 90; $ok.DialogResult = 'OK'
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = (Get-Str 'cancel'); $cancel.Width = 90; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.Add($ok); $buttons.Controls.Add($cancel)
    $dlgRoot.Controls.Add($buttons, 0, 2)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($script:UiForm) -ne 'OK') { return }

    $script:UiConfig.TargetMB = [double]$size.Value
    $script:UiConfig.Minutes = [double]$len.Value
    switch ($quality.SelectedIndex) {
        1 { $script:UiConfig.Quality = 'balanced' }
        2 { $script:UiConfig.Quality = 'fast' }
        default { $script:UiConfig.Quality = 'best' }
    }
    $newGreeting = $greeting.Text.Trim()
    if ($newGreeting -eq ((Get-Str 'greetingDefault')).Trim()) { $newGreeting = '' }
    $script:UiConfig.Greeting = $newGreeting
    $script:UiConfig.To = $to.Text
    $script:UiConfig.NoDrafts = -not $drafts.Checked
    if ($outBox.Text.Trim()) { $script:UiConfig.OutDir = $outBox.Text.Trim() }

    $newCode = $script:LangCodes[$langCombo.SelectedIndex]
    if ($newCode -ne $script:LangCode) {
        Write-AppSetting 'language' $newCode | Out-Null
        Set-AppLanguage $newCode
        # The whole window is rebuilt so the new language (and direction)
        # applies everywhere. Dropped videos are kept.
        $script:RestartGui = $true
        if ($script:UiForm) { $script:UiForm.Close() }
        return
    }

    Update-ListFromInputs
    Update-InputSummary
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:HasGui = $true
    $script:RestartGui = $false
    if (-not $script:Inputs) { $script:Inputs = New-Object System.Collections.ArrayList }
    if (-not $script:UiConfig) {
        $script:UiConfig = @{
            TargetMB = $TargetMB
            Minutes  = $Minutes
            Quality  = $Quality
            Greeting = $Greeting
            To       = $To
            NoDrafts = [bool]$NoDrafts
            OutDir   = $OutDir
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = (Get-Str 'windowTitle')
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(700, 440)
    $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $winW = [math]::Min(800, [math]::Max(700, $work.Width - 16))
    $winH = [math]::Min(560, [math]::Max(440, $work.Height - 16))
    $form.ClientSize = New-Object System.Drawing.Size($winW, $winH)
    if ($work.Width -lt 840 -or $work.Height -lt 600) {
        $form.WindowState = 'Maximized'
    }
    $form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $form.AutoScaleMode = 'Dpi'
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    if ($script:Lang.Rtl) {
        $form.RightToLeft = 'Yes'
        $form.RightToLeftLayout = $true
    }
    $script:UiForm = $form
    $exePath = Join-Path $script:AppDir 'VideoMail.exe'
    if (Test-Path -LiteralPath $exePath) {
        try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath) } catch { }
    }

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 5
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 62))) | Out-Null
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 150))) | Out-Null
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 118))) | Out-Null
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 142))) | Out-Null
    $form.Controls.Add($root)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Fill'
    $header.BackColor = [System.Drawing.Color]::White
    $root.Controls.Add($header, 0, 0)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'VideoMail'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(20, 60, 100)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(20, 8)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = (Get-Str 'subtitle')
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(22, 40)
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(90, 100, 110)
    $header.Controls.Add($subtitle)

    $optPanel = New-Object System.Windows.Forms.Panel
    $optPanel.Dock = 'Right'
    $optPanel.Width = 112
    $optPanel.BackColor = [System.Drawing.Color]::White
    $header.Controls.Add($optPanel)

    $optionsBtn = New-Object System.Windows.Forms.Button
    $optionsBtn.Text = (Get-Str 'options')
    $optionsBtn.Width = 92
    $optionsBtn.Height = 30
    $optionsBtn.Location = New-Object System.Drawing.Point(0, 17)
    $optionsBtn.FlatStyle = 'Flat'
    $optionsBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 210, 220)
    $optionsBtn.BackColor = [System.Drawing.Color]::White
    $optionsBtn.Add_Click({
        try { Show-OptionsDialog }
        catch {
            Write-AppLog ('Options error: ' + $_.Exception.Message)
            [void](Show-MsgBox ((Get-Str 'optError') + "`r`n`r`n" + $_.Exception.Message) 'VideoMail' 'OK' 'Error')
        }
    })
    $optPanel.Controls.Add($optionsBtn)
    $script:UiOptionsBtn = $optionsBtn

    $drop = New-Object System.Windows.Forms.Panel
    $drop.Dock = 'Fill'
    $drop.Margin = New-Object System.Windows.Forms.Padding(18, 10, 18, 6)
    $drop.BackColor = [System.Drawing.Color]::FromArgb(232, 242, 255)
    $drop.BorderStyle = 'FixedSingle'
    $drop.Cursor = 'Hand'
    $drop.AllowDrop = $true
    $root.Controls.Add($drop, 0, 1)
    $script:UiDrop = $drop

    $dropTitle = New-Object System.Windows.Forms.Label
    $dropTitle.Text = (Get-Str 'dragHere')
    $dropTitle.Dock = 'Top'
    $dropTitle.Height = 74
    $dropTitle.TextAlign = 'MiddleCenter'
    $dropTitle.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
    $dropTitle.ForeColor = [System.Drawing.Color]::FromArgb(25, 85, 150)
    $dropTitle.Cursor = 'Hand'
    $drop.Controls.Add($dropTitle)

    $dropSub = New-Object System.Windows.Forms.Label
    $dropSub.Text = (Get-Str 'dropHint')
    $dropSub.Dock = 'Fill'
    $dropSub.TextAlign = 'TopCenter'
    $dropSub.ForeColor = [System.Drawing.Color]::FromArgb(70, 100, 130)
    $dropSub.Cursor = 'Hand'
    $drop.Controls.Add($dropSub)

    foreach ($c in @($drop, $dropTitle, $dropSub)) {
        $c.Add_Click({ Show-OpenVideoDialog })
        $c.Add_DragEnter({
            param($sender, $e)
            if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
                $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            }
        })
        $c.Add_DragDrop({
            param($sender, $e)
            $paths = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
            Add-VideoFiles -Paths $paths
        })
    }

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.Margin = New-Object System.Windows.Forms.Padding(18, 0, 18, 4)
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.MultiSelect = $true
    $list.AllowDrop = $true
    $list.BackColor = [System.Drawing.Color]::White
    if ($script:Lang.Rtl) { $list.RightToLeftLayout = $true }
    [void]$list.Columns.Add((Get-Str 'colVideo'), 420)
    [void]$list.Columns.Add((Get-Str 'colLength'), 80, [System.Windows.Forms.HorizontalAlignment]::Right)
    [void]$list.Columns.Add((Get-Str 'colSize'), 90, [System.Windows.Forms.HorizontalAlignment]::Right)
    [void]$list.Columns.Add((Get-Str 'colParts'), 60, [System.Windows.Forms.HorizontalAlignment]::Right)
    $root.Controls.Add($list, 0, 2)
    $script:UiList = $list

    $list.Add_DragEnter({
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
    })
    $list.Add_DragDrop({
        param($sender, $e)
        Add-VideoFiles -Paths @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    })
    $list.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) { Remove-SelectedVideos }
    })
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    if ($script:Lang.Rtl) {
        $menu.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
    }
    $removeItem = $menu.Items.Add((Get-Str 'removeFromList'))
    $removeItem.Add_Click({ Remove-SelectedVideos })
    $list.ContextMenuStrip = $menu

    $log = New-Object System.Windows.Forms.TextBox
    $log.Dock = 'Fill'
    $log.Margin = New-Object System.Windows.Forms.Padding(18, 0, 18, 4)
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.Font = New-Object System.Drawing.Font('Consolas', 8)
    $log.BackColor = [System.Drawing.Color]::White
    $log.ForeColor = [System.Drawing.Color]::FromArgb(80, 90, 100)
    $root.Controls.Add($log, 0, 3)
    $script:UiLog = $log

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Fill'
    $bottom.BackColor = [System.Drawing.Color]::White
    $root.Controls.Add($bottom, 0, 4)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = (Get-Str 'summaryIdle')
    $summary.Dock = 'Top'
    $summary.Height = 24
    $summary.Padding = New-Object System.Windows.Forms.Padding(20, 5, 20, 0)
    $summary.ForeColor = [System.Drawing.Color]::FromArgb(80, 90, 100)
    $bottom.Controls.Add($summary)
    $script:UiSummary = $summary

    $status = New-Object System.Windows.Forms.Label
    $status.Text = (Get-Str 'ready')
    $status.Dock = 'Top'
    $status.Height = 20
    $status.Padding = New-Object System.Windows.Forms.Padding(20, 0, 20, 0)
    $status.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $bottom.Controls.Add($status)
    $script:UiStatus = $status

    $progressHost = New-Object System.Windows.Forms.Panel
    $progressHost.Dock = 'Top'
    $progressHost.Height = 20
    $progressHost.Padding = New-Object System.Windows.Forms.Padding(20, 4, 20, 4)
    $bottom.Controls.Add($progressHost)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Dock = 'Fill'
    $progress.Maximum = 1000
    $progress.Style = 'Continuous'
    $progressHost.Controls.Add($progress)
    $script:UiProgress = $progress

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = 'Top'
    $buttonPanel.Height = 76
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(20, 8, 20, 8)
    $bottom.Controls.Add($buttonPanel)

    $go = New-Object System.Windows.Forms.Button
    $go.Dock = 'Right'
    $go.Width = 270
    $go.UseMnemonic = $false
    $go.BackColor = [System.Drawing.Color]::FromArgb(22, 121, 74)
    $go.ForeColor = [System.Drawing.Color]::White
    $go.FlatStyle = 'Flat'
    $go.FlatAppearance.BorderSize = 0
    $go.Cursor = 'Hand'
    # Shrink the font until the (possibly long) translated text fits.
    $goText = (Get-Str 'go')
    $goSize = 12.5
    while ($goSize -gt 8.5) {
        $go.Font = New-Object System.Drawing.Font('Segoe UI', $goSize, [System.Drawing.FontStyle]::Bold)
        $textW = [System.Windows.Forms.TextRenderer]::MeasureText($goText, $go.Font).Width
        if ($textW -le 246) { break }
        $goSize -= 0.5
    }
    $go.Text = $goText
    $buttonPanel.Controls.Add($go)
    $script:UiGo = $go

    $mute = New-Object System.Windows.Forms.CheckBox
    $mute.Text = (Get-Str 'mute')
    $mute.AutoSize = $true
    $mute.Location = New-Object System.Drawing.Point(24, 26)
    if ($script:UiMute) { $mute.Checked = $script:UiMute.Checked } else { $mute.Checked = [bool]$Mute }
    $buttonPanel.Controls.Add($mute)
    $script:UiMute = $mute

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = (Get-Str 'cancel')
    $cancel.Dock = 'Right'
    $cancel.Width = 90
    $cancel.Visible = $false
    $cancel.BackColor = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $cancel.FlatStyle = 'Flat'
    $cancel.Add_Click({
        $script:CancelRequested = $true
        $script:UiStatus.Text = (Get-Str 'cancelling')
    })
    $buttonPanel.Controls.Add($cancel)
    $script:UiCancel = $cancel

    # Top-docked controls stack in reverse z-order:
    # summary, status, progress bar, then the buttons at the bottom.
    $bottom.Controls.SetChildIndex($summary, 3)
    $bottom.Controls.SetChildIndex($status, 2)
    $bottom.Controls.SetChildIndex($progressHost, 1)
    $bottom.Controls.SetChildIndex($buttonPanel, 0)

    $go.Add_Click({
        if ($script:UiList.Items.Count -eq 0) {
            [void](Show-MsgBox (Get-Str 'dropFirst') 'VideoMail' 'OK' 'Information')
            return
        }

        $outDir = [string]$script:UiConfig.OutDir
        if (-not $outDir) {
            $outDir = Join-Path (Split-Path -Parent $script:Inputs[0].Path) 'VideoMail parts'
            $script:UiConfig.OutDir = $outDir
        }
        try {
            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
            $probe = Join-Path $outDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII
            Remove-Item -LiteralPath $probe -Force
        } catch {
            [void](Show-MsgBox ((Get-Str 'cannotWrite1') + "`r`n$outDir`r`n`r`n" + (Get-Str 'cannotWrite2')) 'VideoMail' 'OK' 'Warning')
            return
        }

        $script:CancelRequested = $false
        $script:LastPercentShown = -1
        $script:UiProgress.Value = 0
        $script:UiGo.Enabled = $false
        $script:UiCancel.Visible = $true
        $script:UiOptionsBtn.Enabled = $false

        $config = @{
            Inputs    = @($script:Inputs)
            OutDir    = $outDir
            TargetMB  = $script:UiConfig.TargetMB
            Minutes   = $script:UiConfig.Minutes
            Quality   = $script:UiConfig.Quality
            Mute      = $script:UiMute.Checked
            Greeting  = $script:UiConfig.Greeting
            To        = $script:UiConfig.To
            NoDrafts  = $script:UiConfig.NoDrafts
            OnTick    = $null
        }

        try {
            $result = Invoke-Batch -Config $config
            $script:UiProgress.Value = 1000

            if ($result.Cancelled) {
                $script:UiStatus.Text = (Get-Str 'cancelledStatus')
                [void](Show-MsgBox (Get-Str 'cancelledMsg') 'VideoMail' 'OK' 'Information')
            } else {
                $script:UiStatus.Text = (Get-Str 'doneStatus')
                $msg = (Get-Str 'doneBox1') + "`r`n`r`n" + ((Get-Str 'donePartsSaved') -f $result.PartCount) + "`r`n$outDir`r`n`r`n"
                if ($result.DraftMode -eq 'outlook') {
                    $msg += ((Get-Str 'doneOutlook1') -f $result.DraftCount) + "`r`n" + (Get-Str 'doneOutlook2')
                } elseif ($result.DraftMode -eq 'outlook-partial') {
                    $msg += ((Get-Str 'donePartial1') -f $result.DraftCount, $result.DraftError) + "`r`n" + (Get-Str 'donePartial2')
                } elseif ($result.DraftMode -eq 'eml') {
                    $msg += ((Get-Str 'doneEml1') -f $result.DraftCount) + "`r`n$($result.DraftDir)`r`n`r`n" + (Get-Str 'doneEml2')
                } else {
                    $msg += (Get-Str 'doneNoDrafts')
                }
                if ($script:UiConfig.TargetMB -gt 35 -and $result.DraftCount -gt 0) {
                    $msg += "`r`n`r`n" + (Get-Str 'doneHint')
                }
                [void](Show-MsgBox $msg 'VideoMail' 'OK' 'Information')
                try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
                try { Start-Process -FilePath $outDir } catch { }
            }
        } catch {
            $script:UiStatus.Text = (Get-Str 'somethingWrong')
            Write-AppLog ("ERROR: " + $_.Exception.Message)
            [void](Show-MsgBox ((Get-Str 'somethingWrong') + "`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + (Get-Str 'errFatal2') + $script:LogPath) 'VideoMail' 'OK' 'Error')
        } finally {
            $script:UiGo.Enabled = $true
            $script:UiCancel.Visible = $false
            $script:UiOptionsBtn.Enabled = $true
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if ($script:UiGo -and -not $script:UiGo.Enabled) {
            $answer = Show-MsgBox (Get-Str 'workingClose') 'VideoMail' 'YesNo' 'Question'
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $e.Cancel = $true
                return
            }
            $script:CancelRequested = $true
            $script:UiStatus.Text = (Get-Str 'cancelling')
        }
    })

    Update-ListFromInputs
    Update-InputSummary
    [void]$form.ShowDialog()
    return [bool]$script:RestartGui
}

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
