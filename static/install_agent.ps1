# ===================================================================
# Internal Installer - install_agent.ps1 (PowerShell 5.1 compatible)
# ===================================================================

$ErrorActionPreference = "Stop"

$Root = "C:\ProgramData\InternalInstaller"
$AgentPath = Join-Path $Root "agent.ps1"
$TokenPath = Join-Path $Root "agent.token"
$VersionPath = Join-Path $Root "agent.version"

$AgentDownload = "http://10.0.1.103:5050/static/agent.ps1"

# --------------------------
# Helper
# --------------------------
function Write-Step($msg) {
    Write-Host "[STEP] $msg"
}

function Write-OK($msg) {
    Write-Host "[ OK ] $msg"
}

function Write-ErrorMsg($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
}

# --------------------------
# Create folder
# --------------------------
Write-Step "Creating folder..."
if (-not (Test-Path $Root)) {
    New-Item -Path $Root -ItemType Directory | Out-Null
}
Write-OK "Folder ready"

# --------------------------
# Download Agent
# --------------------------
Write-Step "Downloading agent..."
try {
    Invoke-WebRequest -Uri $AgentDownload -OutFile $AgentPath -UseBasicParsing
    Write-OK "Agent downloaded"
} catch {
    Write-ErrorMsg "Failed to download agent.ps1: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit 1
}

# --------------------------
# Token
# --------------------------
Write-Step "Creating token..."
if (-not (Test-Path $TokenPath)) {
    ([guid]::NewGuid().ToString()) | Out-File $TokenPath -Encoding ascii
}
Write-OK "Token ready"

# --------------------------
# Version
# --------------------------
"4.5.0" | Out-File $VersionPath -Encoding ascii
Write-OK "Version stored"

# --------------------------
# Create Scheduled Task
# --------------------------
Write-Step "Creating scheduled task..."

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$AgentPath`""

$Trigger = New-ScheduledTaskTrigger -AtStartup

try {
    Register-ScheduledTask -TaskName "InternalInstallerAgent" `
        -Action $Action `
        -Trigger $Trigger `
        -RunLevel Highest `
        -Force
    Write-OK "Scheduled task created"
} catch {
    Write-ErrorMsg "Scheduled task error: $($_.Exception.Message)"
}

# --------------------------
# Start Agent Manually
# --------------------------
Write-Step "Starting agent..."
try {
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$AgentPath`"" -WindowStyle Hidden
    Write-OK "Agent start requested"
} catch {
    Write-ErrorMsg "Agent start error: $($_.Exception.Message)"
}

# --------------------------
# Test Agent
# --------------------------
Write-Step "Checking agent..."

$ok = $false

for ($i=1; $i -le 8; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:5050/ping" -UseBasicParsing -TimeoutSec 1
        if ($r.StatusCode -eq 200) {
            $ok = $true
            break
        }
    } catch {}
}

if ($ok) {
    Write-OK "Agent is running"
} else {
    Write-ErrorMsg "Agent did NOT start"
}

Write-Host "`nDONE."
Read-Host "Press Enter to exit"
