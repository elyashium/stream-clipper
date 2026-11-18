# clipper: one command for the whole stream -> shorts pipeline (Windows).
# macOS / Linux: use clipper.sh (same commands).
# Works on Windows PowerShell 5.1 and PowerShell 7.
param([Parameter(Position = 0)][string]$Command = "help",
      [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$OsDir = Join-Path $Root "openshorts"
$UpstreamUrl = "https://github.com/mutonby/openshorts"
$UpstreamSha = (Get-Content (Join-Path $Root "stack\UPSTREAM_SHA") -Raw).Trim()
$Api = "http://localhost:8000"
if ($null -eq $Rest) { $Rest = @() }

function Say($msg) { Write-Host $msg -ForegroundColor Cyan }
function Die($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

function Get-EnvValue($name) {
    $file = Join-Path $Root ".env"
    if (-not (Test-Path $file)) { return "" }
    $line = Get-Content $file | Where-Object { $_ -match "^$name=" } | Select-Object -Last 1
    if ($null -eq $line) { return "" }
    return ($line -replace "^$name=", "").Trim()
}

function Invoke-Native {
    # Run a native command; fail loudly on a non-zero exit code.
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { Die "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
}

function Invoke-Quiet {
    # Exit code of a native command with all output discarded. Windows
    # PowerShell 5.1 turns redirected stderr into a terminating error under
    # ErrorActionPreference=Stop, so relax it for the call.
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $Exe @Arguments *> $null; return $LASTEXITCODE } finally { $ErrorActionPreference = $old }
}

function Get-ComposeArgs {
    $a = @("compose", "-p", "clipper", "--project-directory", $OsDir,
           "-f", (Join-Path $OsDir "docker-compose.yml"),
           "-f", (Join-Path $Root "stack\docker-compose.override.yml"))
    if ((Get-EnvValue "USE_GPU") -eq "1") { $a += @("-f", (Join-Path $Root "stack\docker-compose.gpu.yml")) }
    return $a
}

function Invoke-Compose([string[]]$Arguments) {
    Invoke-Native "docker" ((Get-ComposeArgs) + $Arguments)
}

function Test-Command($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Sync-Upstream {
    if (-not (Test-Path (Join-Path $OsDir ".git"))) {
        Invoke-Native "git" @("init", "-q", $OsDir)
        Invoke-Native "git" @("-C", $OsDir, "config", "core.autocrlf", "false")
        Invoke-Native "git" @("-C", $OsDir, "remote", "add", "origin", $UpstreamUrl)
    }
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $head = (& git -C $OsDir rev-parse HEAD 2>$null)
    $ErrorActionPreference = $old
    if ($head -ne $UpstreamSha) {
        Say "Fetching OpenShorts @ $($UpstreamSha.Substring(0,7))..."
        Invoke-Native "git" @("-C", $OsDir, "fetch", "-q", "--depth", "1", "origin", $UpstreamSha)
        Invoke-Native "git" @("-C", $OsDir, "checkout", "-q", "--force", "FETCH_HEAD")
    }
}

function Add-Overlay {
    Copy-Item (Join-Path $Root "stack\overlay\youtube_signals.py") (Join-Path $OsDir "youtube_signals.py") -Force
    $patch = Join-Path $Root "stack\patches\openshorts.patch"
    if ((Invoke-Quiet "git" @("-C", $OsDir, "apply", "--reverse", "--check", $patch)) -eq 0) { return }   # already applied
    & git -C $OsDir apply $patch
    if ($LASTEXITCODE -ne 0) { Die "the patch no longer applies to OpenShorts $UpstreamSha." }
    Say "Applied the YouTube-signals patch."
}

function Initialize-Env {
    foreach ($d in @("clips", "recordings")) {
        $p = Join-Path $Root $d
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
    }
    $envFile = Join-Path $Root ".env"
    if (-not (Test-Path $envFile)) {
        Copy-Item (Join-Path $Root "stack\env.template") $envFile
        Say "Created .env - open it (notepad .env) and paste your GEMINI_API_KEY."
    }
}

function Assert-Keys {
    if (-not (Get-EnvValue "GEMINI_API_KEY") -and -not (Get-EnvValue "LLM_BASE_URL")) {
        Die "GEMINI_API_KEY is empty in .env (free key: https://aistudio.google.com/app/apikey)."
    }
}

function Test-Healthy {
    try { Invoke-WebRequest -Uri "$Api/health" -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}

function Wait-Healthy {
    Write-Host -NoNewline "Waiting for the pipeline to come up"
    for ($i = 0; $i -lt 120; $i++) {
        if (Test-Healthy) { Write-Host " ready."; return }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 3
    }
    Write-Host ""
    Die "the backend did not answer on $Api/health. Look at: .\clipper.ps1 logs"
}

function Invoke-Job([string[]]$Arguments) {
    $a = (Get-ComposeArgs) + @("exec", "backend", "python", "-u", "/stack/run_job.py") + $Arguments
    & docker @a
    exit $LASTEXITCODE
}

function Get-ContainerPath($src) {
    $abs = (Resolve-Path $src).Path
    $rec = (Resolve-Path (Join-Path $Root "recordings")).Path
    if ($abs.StartsWith($rec + "\", [StringComparison]::OrdinalIgnoreCase)) {
        return "/recordings/" + ($abs.Substring($rec.Length + 1) -replace "\\", "/")
    }
    $name = Split-Path $abs -Leaf
    $dest = Join-Path $rec $name
    if (-not (Test-Path $dest)) {
        Say "Copying $name into recordings\ (set OBS to record straight into that folder to skip this)..."
        Copy-Item $abs $dest
    }
    return "/recordings/$name"
}

function Show-Usage {
    @"
clipper - stream -> vertical shorts, locally, no watermark.

  .\clipper.ps1 setup              download OpenShorts, apply the patch, build (first time / after update)
  .\clipper.ps1 start              start the pipeline + dashboard (http://localhost:5175)
  .\clipper.ps1 run <url|file> [--clips N] [--min S] [--max S]
                                   clip a YouTube VOD link or a local OBS recording
  .\clipper.ps1 post <job> <n> [--platforms tiktok,youtube,instagram] [--schedule ISO]
  .\clipper.ps1 jobs               list the clip folders in clips\
  .\clipper.ps1 logs               follow the backend log
  .\clipper.ps1 stop               stop everything
  .\clipper.ps1 update             pull this repo and rebuild
  .\clipper.ps1 doctor             check this machine
"@ | Write-Host
}

switch ($Command) {
    "setup" {
        if (-not (Test-Command git)) { Die "git is not installed: winget install Git.Git" }
        if (-not (Test-Command docker)) { Die "Docker is not installed: https://docs.docker.com/desktop/setup/install/windows-install/" }
        if ((Invoke-Quiet "docker" @("info")) -ne 0) { Die "Docker is installed but not running. Start Docker Desktop." }
        Sync-Upstream; Add-Overlay; Initialize-Env
        Say "Building the images (the first build downloads several GB, 10-30 min)..."
        Invoke-Compose @("build")
        Invoke-Compose @("up", "-d")
        Wait-Healthy
        Say "Setup done. Dashboard: http://localhost:5175"
        if (-not (Get-EnvValue "GEMINI_API_KEY")) { Say "Next: put GEMINI_API_KEY in .env, then .\clipper.ps1 start" }
    }
    "start" {
        if (-not (Test-Path (Join-Path $OsDir ".git"))) { Die "run .\clipper.ps1 setup first." }
        Initialize-Env; Add-Overlay
        Invoke-Compose @("up", "-d"); Wait-Healthy
        Say "Dashboard: http://localhost:5175"
    }
    "stop" { Invoke-Compose @("down") }
    "logs" { Invoke-Compose @("logs", "-f", "--tail", "200", "backend") }
    "run" {
        if ($Rest.Count -lt 1) { Die "usage: .\clipper.ps1 run <youtube-url | recording-file> [--clips N]" }
        if (-not (Test-Path (Join-Path $OsDir ".git"))) { Die "run .\clipper.ps1 setup first." }
        Assert-Keys
        $src = $Rest[0]
        $more = @()
        if ($Rest.Count -gt 1) { $more = $Rest[1..($Rest.Count - 1)] }
        if (Test-Path -LiteralPath $src -PathType Leaf) { $src = Get-ContainerPath $src }
        elseif ($src -notmatch "^https?://") { Die "$src is neither a URL nor a file." }
        if (-not (Test-Healthy)) { Invoke-Compose @("up", "-d"); Wait-Healthy }
        Invoke-Job (@("process", $src) + $more)
    }
    "post" { Invoke-Job (@("post") + $Rest) }
    "jobs" { Invoke-Job @("jobs") }
    "update" {
        Invoke-Native "git" @("-C", $Root, "pull", "--ff-only")
        & (Join-Path $Root "clipper.ps1") setup
    }
    "doctor" {
        foreach ($c in @("git", "docker")) { if (Test-Command $c) { "ok   $c" } else { "MISS $c" } }
        if ((Invoke-Quiet "docker" @("info")) -eq 0) { "ok   docker running" } else { "MISS docker is not running" }
        if (Test-Command nvidia-smi) { "gpu  " + (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader) }
        else { "info no NVIDIA GPU (CPU mode, slower)" }
        if (Test-Path (Join-Path $Root ".env")) { "ok   .env" } else { "MISS .env (run setup)" }
        if (Get-EnvValue "GEMINI_API_KEY") { "ok   GEMINI_API_KEY" } else { "MISS GEMINI_API_KEY" }
        if (Get-EnvValue "UPLOAD_POST_API_KEY") { "ok   UPLOAD_POST_API_KEY" } else { "info no UPLOAD_POST_API_KEY (posting off)" }
        if (Test-Healthy) { "ok   pipeline running" } else { "info pipeline not running (.\clipper.ps1 start)" }
    }
    default { Show-Usage }
}
