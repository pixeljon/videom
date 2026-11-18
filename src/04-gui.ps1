
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
