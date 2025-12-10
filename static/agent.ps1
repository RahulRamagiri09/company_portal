# Internal Installer Agent v4.6 (PS 5.1 compatible)
$ErrorActionPreference = "Continue"

# config
$ListenAddress = "127.0.0.1"
$ListenPort = 5050
$Version = "4.6.0"
$AgentRoot = "C:\ProgramData\InternalInstaller"
$LogFile = Join-Path $AgentRoot "agent.log"
$ServerBase = "http://10.0.1.103:5050"   # central server

# ensure folder
if (-not (Test-Path $AgentRoot)) { New-Item -Path $AgentRoot -ItemType Directory -Force | Out-Null }

function Log {
    param([string]$m)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $LogFile -Value ("{0}`t{1}" -f $ts, $m) -Force
    } catch {}
}

Log ("Agent v{0} starting..." -f $Version)

# create listener
$addr = [System.Net.IPAddress]::Parse($ListenAddress)
$listener = New-Object System.Net.Sockets.TcpListener($addr, $ListenPort)
$listener.Start()
Log ("Listener started on {0}:{1}" -f $ListenAddress, $ListenPort)

# helper to write JSON + CORS headers
function Send-JsonResponse {
    param([System.Net.Sockets.TcpClient]$client, [object]$obj, [int]$statusCode = 200)
    try {
        $json = $obj | ConvertTo-Json -Depth 6
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream = $client.GetStream()
        $hdr = ("HTTP/1.1 {0} OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: {1}`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nConnection: close`r`n`r`n" -f $statusCode, $bytes.Length)
        $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($hdr)
        $stream.Write($hdrBytes, 0, $hdrBytes.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        Log ("Send-JsonResponse error: {0}" -f $_.Exception.Message)
    } finally {
        try { $client.Close() } catch {}
    }
}

# helper: read basic HTTP request from client stream
function Read-HttpRequest {
    param([System.Net.Sockets.TcpClient]$client)
    try {
        $stream = $client.GetStream()
        $sr = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false)
        $reqLine = $sr.ReadLine()
        if (-not $reqLine) { return $null }
        $parts = $reqLine.Split(" ")
        $method = $parts[0]
        $path = $parts[1]
        $headers = @{}
        while ($true) {
            $h = $sr.ReadLine()
            if ($h -eq $null) { break }
            if ($h -eq "") { break }
            $idx = $h.IndexOf(":")
            if ($idx -gt -1) {
                $hn = $h.Substring(0,$idx).Trim().ToLower()
                $hv = $h.Substring($idx+1).Trim()
                $headers[$hn] = $hv
            }
        }
        $body = ""
        if ($headers.ContainsKey("content-length")) {
            $cl = 0
            try { $cl = [int]$headers["content-length"] } catch {}
            if ($cl -gt 0) {
                $buf = New-Object byte[] $cl
                $read = 0
                $base = $client.GetStream()
                while ($read -lt $cl) {
                    $rc = $base.Read($buf,$read,$cl - $read)
                    if ($rc -le 0) { break }
                    $read += $rc
                }
                $body = [System.Text.Encoding]::UTF8.GetString($buf,0,$read)
            }
        }
        return @{ method = $method; path = $path; headers = $headers; body = $body }
    } catch {
        return $null
    }
}

# simple helpers for installations
function Is-ChocoInstalled {
    param([string]$pkg)
    try {
        $out = choco list --local-only --exact $pkg 2>$null
        if ($out -and ($out -match ("^" + [regex]::Escape($pkg) + "\s"))) { return $true }
        return $false
    } catch { return $false }
}

function Install-Choco {
    param([string]$pkg)
    try {
        if (Is-ChocoInstalled $pkg) { return $true }
        $proc = Start-Process -FilePath "choco" -ArgumentList "install",$pkg,"-y","--no-progress" -Wait -PassThru -ErrorAction Stop
        return ($proc.ExitCode -eq 0)
    } catch {
        Log ("Install-Choco error: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Install-Local {
    param([string]$relPath)
    try {
        if (-not $relPath) { return $false }
        $rel = $relPath.TrimStart("/","\") 
        $url = $ServerBase.TrimEnd("/") + "/installers/" + $rel
        $tmp = Join-Path $env:TEMP ("inst_" + [guid]::NewGuid().ToString() + [IO.Path]::GetExtension($rel))
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        if ($tmp.ToLower().EndsWith(".msi")) {
            $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tmp`" /qn /norestart" -Wait -PassThru -ErrorAction Stop
        } else {
            $argsList = @("/S","/silent","/verysilent","/qn")
            $succeeded = $false
            foreach ($a in $argsList) {
                try {
                    $p = Start-Process -FilePath $tmp -ArgumentList $a -Wait -PassThru -ErrorAction Stop
                    if ($p.ExitCode -eq 0) { $succeeded = $true; break }
                } catch {}
            }
            if (-not $succeeded) {
                try { $p = Start-Process -FilePath $tmp -ArgumentList "" -Wait -PassThru -ErrorAction Stop } catch {}
            }
        }
        $exit = $null
        try { $exit = $p.ExitCode } catch {}
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return ($exit -eq 0)
    } catch {
        Log ("Install-Local error: {0}" -f $_.Exception.Message)
        return $false
    }
}

# Helper to get local hostname & first non-loopback IPv4
function Get-LocalInfo {
    $h = $env:COMPUTERNAME
    $ip = "unknown"
    try {
        $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1 -ExpandProperty IPAddress
        if ($addr) { $ip = $addr }
    } catch {}
    return @{ hostname = $h; ip = $ip }
}

# Main loop
while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
    } catch {
        Start-Sleep -Milliseconds 200
        continue
    }

    if (-not $client) { continue }
    $req = Read-HttpRequest -client $client
    if (-not $req) { try { $client.Close() } catch {}; continue }

    $method = $req.method
    $path = $req.path
    Log ("REQ {0} {1}" -f $method, $path)

    # handle OPTIONS preflight quickly
    if ($method -eq "OPTIONS") {
        try {
            $stream = $client.GetStream()
            $hdr = "HTTP/1.1 204 No Content`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($hdr)
            $stream.Write($hdrBytes,0,$hdrBytes.Length)
            $stream.Flush()
        } catch {}
        try { $client.Close() } catch {}
        continue
    }

    # normalize path (strip query)
    $pathOnly = $path
    if ($pathOnly -match "\?") {
        $idx = $pathOnly.IndexOf("?")
        if ($idx -ge 0) { $pathOnly = $pathOnly.Substring(0,$idx) }
    }

    try {
        if ($method -eq "GET" -and $pathOnly -eq "/ping") {
            $info = Get-LocalInfo
            Send-JsonResponse -client $client -obj @{ ok = $true; version = $Version; hostname = $info.hostname; ip = $info.ip } -statusCode 200
            continue
        }

        if ($method -eq "GET" -and $pathOnly -eq "/status") {
            Send-JsonResponse -client $client -obj @{ installed = $true; running = $true; version = $Version } -statusCode 200
            continue
        }

        if ($method -eq "GET" -and $pathOnly -eq "/installed") {
            # query like ?source=choco&package=vscode
            $q = @{ installed = $false }
            if ($req.path -match "\?") {
                $raw = $req.path.Substring($req.path.IndexOf("?")+1)
                $pairs = $raw.Split("&")
                foreach ($p in $pairs) {
                    $parts = $p.Split("=")
                    if ($parts.Length -ge 2) { $q[$parts[0]] = [System.Uri]::UnescapeDataString($parts[1]) }
                }
            }
            $ins = $false
            if ($q.ContainsKey("source") -and $q["source"] -eq "choco" -and $q.ContainsKey("package")) {
                $ins = Is-ChocoInstalled $q["package"]
            }
            Send-JsonResponse -client $client -obj @{ installed = $ins } -statusCode 200
            continue
        }

        if ($method -eq "POST" -and $pathOnly -eq "/install") {
            $body = $req.body
            if (-not $body) {
                Send-JsonResponse -client $client -obj @{ status = "error"; message = "missing_body" } -statusCode 400
                continue
            }
            try {
                $payload = $body | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Send-JsonResponse -client $client -obj @{ status = "error"; message = "invalid_json" } -statusCode 400
                continue
            }
            if (-not $payload.app) {
                Send-JsonResponse -client $client -obj @{ status = "error"; message = "missing_app" } -statusCode 400
                continue
            }
            $a = $payload.app
            $ok = $false
            try {
                if ($a.source -eq "choco" -and $a.package) {
                    $ok = Install-Choco $a.package
                } elseif ($a.source -eq "local" -and $a.installer_path) {
                    $ok = Install-Local $a.installer_path
                } else {
                    $ok = $false
                }
            } catch {
                Log ("Install handler exception: {0}" -f $_.Exception.Message)
                $ok = $false
            }
            if ($ok) { Send-JsonResponse -client $client -obj @{ status = "ok"; message = "installed" } -statusCode 200 }
            else { Send-JsonResponse -client $client -obj @{ status = "error"; message = "install_failed" } -statusCode 500 }
            continue
        }

        # default not found
        Send-JsonResponse -client $client -obj @{ error = "not_found" } -statusCode 404

    } catch {
        Log ("Loop error: {0}" -f $_.Exception.Message)
        try { $client.Close() } catch {}
    }
}
