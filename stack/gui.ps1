# Stream Clipper window. Started by "Stream Clipper.cmd" (or .\clipper.ps1 gui).
# Plain Windows Forms on Windows PowerShell 5.1: nothing to install.
# Every long task runs clipper.ps1 in its own console window so the log stays
# visible; this window only shows status, keeps the keys and launches things.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Win32 -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win32.Dpi]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = Split-Path $PSScriptRoot -Parent
$EnvFile = Join-Path $Root ".env"
$Clipper = Join-Path $Root "clipper.ps1"
$Dashboard = "http://localhost:5175/#app"
$DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"

# ---- .env ------------------------------------------------------------------
function Initialize-EnvFile {
    if (Test-Path $EnvFile) { return }
    Copy-Item (Join-Path $Root "stack\env.template") $EnvFile
    if ($script:GpuName) { Set-EnvValue "USE_GPU" "1" }
}
function Get-EnvValue($name) {
    if (-not (Test-Path $EnvFile)) { return "" }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^$name=" } | Select-Object -Last 1
    if ($null -eq $line) { return "" }
    return ($line -replace "^$name=", "").Trim()
}
function Set-EnvValue($name, $value) {
    $value = ($value -replace "[\r\n]", "").Trim()
    $found = $false
    $lines = @(Get-Content $EnvFile | ForEach-Object {
        if ($_ -match "^$name=") { $found = $true; "$name=$value" } else { $_ }
    })
    if (-not $found) { $lines += "$name=$value" }
    [IO.File]::WriteAllLines($EnvFile, [string[]]$lines)
}

# ---- status probes (all fast: no docker CLI calls on the UI thread) --------
function Get-GpuName {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return "" }
    try {
        $n = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $n) { return "$n".Trim() }
    } catch {}
    return ""
}
function Test-DockerInstalled { return [bool](Get-Command docker -ErrorAction SilentlyContinue) -or (Test-Path $DockerExe) }
function Test-DockerRunning { return (Test-Path "\\.\pipe\docker_engine") -or (Test-Path "\\.\pipe\dockerDesktopLinuxEngine") }
function Test-Installed { return Test-Path (Join-Path $Root "openshorts\.git") }
function Test-PipelineUp {
    try {
        $r = [Net.WebRequest]::Create("http://127.0.0.1:8000/health")
        $r.Timeout = 700
        $resp = $r.GetResponse(); $ok = [int]$resp.StatusCode -eq 200; $resp.Close(); return $ok
    } catch { return $false }
}

# ---- actions ---------------------------------------------------------------
function Start-Clipper([string[]]$Arguments, [string]$Title) {
    # New console that stays open, so the user can read the result.
    $quoted = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '') + '"' }) -join " "
    $cmd = "`$host.UI.RawUI.WindowTitle = 'Stream Clipper - $Title'; & '$($Clipper -replace "'", "''")' $quoted; " +
           "Write-Host ''; Write-Host 'Finished. You can close this window.' -ForegroundColor Green"
    Start-Process powershell -WorkingDirectory $Root -ArgumentList @(
        "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
}
function Assert-Ready([switch]$NeedKey) {
    if (-not (Test-DockerInstalled)) {
        if (Ask "Docker Desktop is not installed. Open the download page?") {
            Start-Process "https://docs.docker.com/desktop/setup/install/windows-install/" }
        return $false
    }
    if (-not (Test-DockerRunning)) {
        if (Test-Path $DockerExe) { Start-Process $DockerExe; Set-Status }
        Tell "Docker Desktop is starting. Wait until its whale icon stops animating, then click again."
        return $false
    }
    if (-not (Test-Installed)) { Tell "Click 'Install' first (one time)."; return $false }
    if ($NeedKey -and -not (Get-EnvValue "GEMINI_API_KEY") -and -not (Get-EnvValue "LLM_BASE_URL")) {
        Tell "Paste your Gemini key and click Save first."; return $false
    }
    return $true
}
function Tell($msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, "Stream Clipper") }
function Ask($msg) {
    return [System.Windows.Forms.MessageBox]::Show($msg, "Stream Clipper", "YesNo") -eq "Yes"
}

# ---- layout ----------------------------------------------------------------
$font = New-Object System.Drawing.Font("Segoe UI", 10)
$bold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$form = New-Object System.Windows.Forms.Form
$form.Text = "Stream Clipper"
$form.Font = $font
$form.AutoScaleMode = "Dpi"
$form.AutoSize = $true
$form.AutoSizeMode = "GrowAndShrink"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Padding = New-Object System.Windows.Forms.Padding(12)

$main = New-Object System.Windows.Forms.FlowLayoutPanel
$main.FlowDirection = "TopDown"; $main.AutoSize = $true; $main.WrapContents = $false
$form.Controls.Add($main)

function New-Group($title) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $title; $g.Font = $bold; $g.AutoSize = $true
    $g.MinimumSize = New-Object System.Drawing.Size(660, 0); $g.MaximumSize = New-Object System.Drawing.Size(660, 0)
    $g.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 8)
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.AutoSize = $true; $t.Dock = "Fill"; $t.Font = $font; $t.ColumnCount = 3
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("AutoSize")))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("Percent", 100)))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle("AutoSize")))
    $g.Controls.Add($t); $main.Controls.Add($g)
    return $t
}
function New-Label($text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.Anchor = "Left"
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 7, 8, 3)
    return $l
}
function New-Button($text, $onClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    $b.Add_Click($onClick)
    return $b
}
function New-Link($text, $url) {
    $l = New-Object System.Windows.Forms.LinkLabel
    $l.Text = $text; $l.AutoSize = $true; $l.Anchor = "Left"
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
    $l.Add_LinkClicked({ Start-Process $url }.GetNewClosure())
    return $l
}

# Status
$st = New-Group "Status"
$lblDocker = New-Label ""; $lblGpu = New-Label ""; $lblPipe = New-Label ""
foreach ($l in @($lblDocker, $lblGpu, $lblPipe)) { $l.MaximumSize = New-Object System.Drawing.Size(540, 0) }
$st.Controls.Add((New-Label "Docker"), 0, 0); $st.Controls.Add($lblDocker, 1, 0)
$st.Controls.Add((New-Label "Graphics"), 0, 1); $st.Controls.Add($lblGpu, 1, 1)
$st.Controls.Add((New-Label "Pipeline"), 0, 2); $st.Controls.Add($lblPipe, 1, 2)

# Keys
$kt = New-Group "Keys (saved to .env on this PC only)"
function New-KeyBox($secret) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Dock = "Fill"; $tb.UseSystemPasswordChar = $secret; $tb.MinimumSize = New-Object System.Drawing.Size(340, 0)
    $tb.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)
    return $tb
}
$tbGemini = New-KeyBox $true; $tbUpKey = New-KeyBox $true; $tbUpUser = New-KeyBox $false
$kt.Controls.Add((New-Label "Gemini key (required)"), 0, 0); $kt.Controls.Add($tbGemini, 1, 0)
$kt.Controls.Add((New-Link "get one free" "https://aistudio.google.com/app/apikey"), 2, 0)
$kt.Controls.Add((New-Label "Upload-Post key"), 0, 1); $kt.Controls.Add($tbUpKey, 1, 1)
$kt.Controls.Add((New-Link "for posting" "https://www.upload-post.com"), 2, 1)
$kt.Controls.Add((New-Label "Upload-Post profile"), 0, 2); $kt.Controls.Add($tbUpUser, 1, 2)
$keyRow = New-Object System.Windows.Forms.FlowLayoutPanel
$keyRow.AutoSize = $true; $keyRow.Dock = "Fill"
$cbShow = New-Object System.Windows.Forms.CheckBox
$cbShow.Text = "show keys"; $cbShow.AutoSize = $true; $cbShow.Margin = New-Object System.Windows.Forms.Padding(3, 8, 12, 3)
$cbShow.Add_CheckedChanged({ $tbGemini.UseSystemPasswordChar = -not $cbShow.Checked; $tbUpKey.UseSystemPasswordChar = -not $cbShow.Checked })
$btnSave = New-Button "Save keys" {
    Initialize-EnvFile
    Set-EnvValue "GEMINI_API_KEY" $tbGemini.Text
    Set-EnvValue "UPLOAD_POST_API_KEY" $tbUpKey.Text
    Set-EnvValue "UPLOAD_POST_USER" $tbUpUser.Text
    if (Test-PipelineUp) {
        # The backend reads .env at start: recreate it so the keys apply now.
        Start-Clipper @("start") "applying keys"
    }
    $btnSave.Text = "Saved"
}
$keyRow.Controls.Add($cbShow); $keyRow.Controls.Add($btnSave)
$kt.Controls.Add($keyRow, 1, 3)
foreach ($tb in @($tbGemini, $tbUpKey, $tbUpUser)) { $tb.Add_TextChanged({ $btnSave.Text = "Save keys" }) }

# Actions
$at = New-Group "Pipeline"
$row = New-Object System.Windows.Forms.FlowLayoutPanel
$row.AutoSize = $true; $row.Dock = "Fill"
$at.Controls.Add($row, 0, 0); $at.SetColumnSpan($row, 3)
$btnInstall = New-Button "Install" {
    if (-not (Test-DockerInstalled)) { [void](Assert-Ready); return }
    if (-not (Test-DockerRunning)) { [void](Assert-Ready); return }
    Initialize-EnvFile
    Start-Clipper @("setup") "install"
}
$btnStart = New-Button "Start" { if (Assert-Ready) { Start-Clipper @("start") "start" } }
$btnDash = New-Button "Open dashboard" {
    if (Test-PipelineUp) { Start-Process $Dashboard }
    elseif (Assert-Ready) { Start-Clipper @("open") "starting" }
}
$btnClips = New-Button "Open clips folder" {
    $dir = Join-Path $Root "clips"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
    if (Test-PipelineUp) {
        # Pull in clips of jobs started from the dashboard, then show the folder.
        Start-Process powershell -WindowStyle Hidden -Wait -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Clipper, "sync")
    }
    Start-Process explorer.exe $dir
}
$btnLogs = New-Button "Logs" { if (Assert-Ready) { Start-Clipper @("logs") "logs" } }
$btnStop = New-Button "Stop" { if (Assert-Ready) { Start-Clipper @("stop") "stop" } }
foreach ($b in @($btnInstall, $btnStart, $btnDash, $btnClips, $btnLogs, $btnStop)) { $row.Controls.Add($b) }

# Clip
$ct = New-Group "Make clips"
$tbUrl = New-Object System.Windows.Forms.TextBox
$tbUrl.Dock = "Fill"; $tbUrl.MinimumSize = New-Object System.Drawing.Size(340, 0); $tbUrl.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)
$numClips = New-Object System.Windows.Forms.NumericUpDown
$numClips.Minimum = 0; $numClips.Maximum = 50; $numClips.Width = 60
$numClips.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)
function Get-ClipArgs { if ($numClips.Value -gt 0) { return @("--clips", [string][int]$numClips.Value) } return @() }
$btnUrl = New-Button "Clip this link" {
    $u = $tbUrl.Text.Trim()
    if ($u -notmatch "^https?://") { Tell "Paste a YouTube link first (the stream's VOD, once the stream has ended)."; return }
    if (-not (Assert-Ready -NeedKey)) { return }
    Start-Clipper (@("run", $u) + (Get-ClipArgs)) "clipping"
}
$btnFile = New-Button "Clip a recording..." {
    if (-not (Assert-Ready -NeedKey)) { return }
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = "Pick the OBS recording"
    $d.InitialDirectory = Join-Path $Root "recordings"
    $d.Filter = "Videos|*.mp4;*.mkv;*.mov;*.flv;*.webm|All files|*.*"
    if ($d.ShowDialog() -eq "OK") { Start-Clipper (@("run", $d.FileName) + (Get-ClipArgs)) "clipping" }
}
$ct.Controls.Add((New-Label "YouTube link"), 0, 0); $ct.Controls.Add($tbUrl, 1, 0); $ct.Controls.Add($btnUrl, 2, 0)
$ct.Controls.Add((New-Label "Number of clips"), 0, 1)
$clipRow = New-Object System.Windows.Forms.FlowLayoutPanel
$clipRow.AutoSize = $true; $clipRow.Dock = "Fill"
$clipRow.Controls.Add($numClips); $clipRow.Controls.Add((New-Label "0 = let the AI decide"))
$ct.Controls.Add($clipRow, 1, 1); $ct.Controls.Add($btnFile, 2, 1)

$hint = New-Label ""
$hint.MaximumSize = New-Object System.Drawing.Size(660, 0)
$hint.ForeColor = [System.Drawing.Color]::DimGray
$main.Controls.Add($hint)

# ---- status refresh --------------------------------------------------------
$green = [System.Drawing.Color]::FromArgb(0, 128, 60)
$red = [System.Drawing.Color]::FromArgb(190, 30, 30)
$amber = [System.Drawing.Color]::FromArgb(170, 110, 0)
function Set-Line($label, $text, $color) { $label.Text = $text; $label.ForeColor = $color }
function Set-Status {
    $dockerUp = Test-DockerRunning
    if (-not (Test-DockerInstalled)) { Set-Line $lblDocker "not installed (Install shows the download)" $red }
    elseif ($dockerUp) { Set-Line $lblDocker "running" $green }
    else { Set-Line $lblDocker "not running (Start launches Docker Desktop)" $amber }

    $useGpu = (Get-EnvValue "USE_GPU") -eq "1"
    if (-not $script:GpuName) { Set-Line $lblGpu "no NVIDIA card found: CPU mode (slower)" $amber }
    elseif ($useGpu -or -not (Test-Path $EnvFile)) { Set-Line $lblGpu "$($script:GpuName) - GPU mode" $green }
    else { Set-Line $lblGpu "$($script:GpuName) - off (USE_GPU=0 in .env)" $amber }

    $installed = Test-Installed
    $up = $dockerUp -and (Test-PipelineUp)
    if ($up) { Set-Line $lblPipe "running - dashboard at localhost:5175" $green }
    elseif ($installed) { Set-Line $lblPipe "installed, stopped" $amber }
    else { Set-Line $lblPipe "not installed yet" $red }

    $btnInstall.Text = if ($installed) { "Update / rebuild" } else { "Install (one time, ~20 min)" }
    $btnStart.Enabled = $installed -and -not $up
    $btnStop.Enabled = $up
    if (-not $installed) {
        $hint.Text = "First time: 1) paste the Gemini key, Save  2) Install. A console window shows the progress; leave it running."
    } elseif (-not $up) {
        $hint.Text = "Click Start (about a minute), or just clip a link: it starts the pipeline by itself."
    } else {
        $hint.Text = "Clips land in the clips folder with their titles and captions. Review, edit and post them in the dashboard."
    }
}

$script:GpuName = Get-GpuName
$tbGemini.Text = Get-EnvValue "GEMINI_API_KEY"
$tbUpKey.Text = Get-EnvValue "UPLOAD_POST_API_KEY"
$tbUpUser.Text = Get-EnvValue "UPLOAD_POST_USER"
$btnSave.Text = "Save keys"

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ try { Set-Status } catch {} })
$form.Add_Shown({ Set-Status; $timer.Start(); $tbUrl.Focus() })
$form.Add_FormClosed({ $timer.Stop() })
[void]$form.ShowDialog()
