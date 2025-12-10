<#
    Internal Installer Agent v4.2
    ---------------------------------
    Runs a local HTTP API on:
        http://localhost:5050/

    Endpoints:
        /ping                  → Health check from employee UI
        /install?app_id=123   → Install application

    Works with your FastAPI server on port 5050.
#>

Add-Type -AssemblyName System.Net.HttpListener

# ------------------------------
# CONFIGURATION
# ------------------------------
$ServerURL = "http://10.0.1.103:5050"     # 🔥 UPDATE YOUR SERVER IP HERE
$ListenerURL = "http://localhost:5050/"  # Local agent port
$TempInstaller = "$env:TEMP\internal_installer.exe"

# ------------------------------
# START HTTP LISTENER
# ------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($ListenerURL)
$listener.Start()

Write-Host "Internal Installer Agent listening at $ListenerURL" -ForegroundColor Green


# ------------------------------
# INSTALL APPLICATION FUNCTION
# ------------------------------
function Install-App {
    param([int]$AppId)

    try {
        # 1. GET APPLICATION DETAILS FROM SERVER
        $app = Invoke-RestMethod "$ServerURL/api/apps/$AppId"

        Write-Host "Requested install of: $($app.name)" -ForegroundColor Cyan
        Write-Host "Source: $($app.source)" -ForegroundColor DarkGray

        # 2. INSTALLATION BASED ON SOURCE TYPE
        if ($app.source -eq "choco") {

            Write-Host "Installing via Chocolatey: $($app.package)"
            choco install $app.package -y --no-progress

        }
        elseif ($app.source -eq "local") {

            if (-not $app.installer_path) {
                throw "Local installer path missing in server response."
            }

            $url = "$ServerURL/$($app.installer_path)"

            Write-Host "Downloading installer: $url"
            Invoke-WebRequest -Uri $url -OutFile $TempInstaller -UseBasicParsing

            Write-Host "Running installer..."
            Start-Process $TempInstaller -ArgumentList "/silent", "/S", "/qn" -Wait
        }
        else {
            throw "Unknown source type: $($app.source)"
        }

        # 3. LOG SUCCESS
        Invoke-RestMethod "$ServerURL/api/logs" -Method POST -ContentType "application/json" -Body (@{
            agent_id = $env:COMPUTERNAME
            app_name = $app.name
            status   = "success"
            message  = "App installed successfully."
        } | ConvertTo-Json)

        return "SUCCESS: Installed $($app.name)"
    }
    catch {
        $errorMsg = $_.Exception.Message

        # Log failure to server
        Invoke-RestMethod "$ServerURL/api/logs" -Method POST -ContentType "application/json" -Body (@{
            agent_id = $env:COMPUTERNAME
            app_name = ($app.name)
            status   = "failure"
            message  = $errorMsg
        } | ConvertTo-Json)

        return "ERROR: $errorMsg"
    }
}


# ------------------------------
# MAIN LOOP – HANDLE HTTP REQUESTS
# ------------------------------
while ($true) {
    $context = $listener.GetContext()
    $req = $context.Request
    $res = $context.Response

    $responseMessage = ""

    switch ($req.Url.AbsolutePath) {

        "/install" {
            $appId = $req.QueryString["app_id"]

            if (-not $appId) {
                $responseMessage = "Missing ?app_id="
            }
            else {
                Write-Host "Received install request for App ID $appId" -ForegroundColor Yellow
                $responseMessage = Install-App -AppId $appId
            }
        }

        "/ping" {
            $responseMessage = "OK"
        }

        default {
            $responseMessage = "Agent OK"
        }
    }

    # Send response
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseMessage)
    $res.OutputStream.Write($buffer, 0, $buffer.Length)
    $res.Close()
}
