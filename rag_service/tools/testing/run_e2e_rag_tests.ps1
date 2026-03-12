param()

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ragServiceDir = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$logDir = Join-Path $scriptDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "run_e2e_rag_tests_${timestamp}.log"

Start-Transcript -Path $logFile -Force | Out-Null

Write-Host ""
Write-Host "========== [STEP] Verifying expected directories =========="
Write-Host "[test] SCRIPT_DIR=$scriptDir"
Write-Host "[test] RAG_SERVICE_DIR=$ragServiceDir"

if (-not (Test-Path (Join-Path $ragServiceDir 'app'))) {
    Write-Error "Could not find rag_service/app under $ragServiceDir"
    Stop-Transcript | Out-Null
    exit 1
}

$venvScripts = Join-Path $ragServiceDir '.venv\Scripts'
$pythonExe = Join-Path $venvScripts 'python.exe'

Write-Host ""
Write-Host "========== [STEP] Activating virtualenv =========="
if (-not (Test-Path $pythonExe)) {
    Write-Error "Could not find venv python at $pythonExe"
    Stop-Transcript | Out-Null
    exit 1
}

$env:PATH = "$venvScripts;$env:PATH"

& $pythonExe -V

Write-Host ""
Write-Host "========== [STEP] Starting backend (uvicorn) in background =========="

Push-Location $ragServiceDir
try {
    $uvicornArgs = "-m uvicorn app.main:app --host 0.0.0.0 --port 8000"
    Write-Host "[test] Command: python $uvicornArgs"

    $backend = Start-Process -FilePath $pythonExe -ArgumentList $uvicornArgs -WorkingDirectory $ragServiceDir -PassThru
    $backendPid = $backend.Id
    Write-Host "[test] Backend PID=$backendPid"
}
finally {
    Pop-Location
}

try {
    Write-Host ""
    Write-Host "========== [STEP] Waiting for /health to become ready =========="

    $healthUrl = "http://127.0.0.1:8000/health"
    $maxAttempts = 30
    $sleepSeconds = 1

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host "[test] Health check attempt $attempt/$maxAttempts..."
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -Method Get -TimeoutSec 5
            if ($resp.StatusCode -eq 200) {
                Write-Host "[test] Backend is healthy (HTTP 200)."
                break
            }
        }
        catch {
            Start-Sleep -Seconds $sleepSeconds
        }
    }

    if ($attempt -gt $maxAttempts) {
        throw "Backend /health did not return 200 within $maxAttempts seconds."
    }

    function Invoke-RagQuery {
        param(
            [string] $Name,
            [hashtable] $Body
        )

        Write-Host ""
        Write-Host "========== [STEP] Running test: $Name =========="
        $json = $Body | ConvertTo-Json -Depth 8
        Write-Host "[test] Request payload:"
        $json.Split("`n") | ForEach-Object { Write-Host "[test]   $_" }

        $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8000/query" -Method Post -ContentType "application/json" -Body $json
        Write-Host "[test] HTTP status: $($resp.StatusCode)"
        if ($resp.StatusCode -ne 200) {
            Write-Host "[test] Body:"
            Write-Host $resp.Content
            throw "Unexpected HTTP status for test '$Name': $($resp.StatusCode)"
        }

        Write-Host "[test] Response for '$Name':"
        Write-Host $resp.Content
    }

    Invoke-RagQuery -Name "Basic docs + code query (GDScript)" -Body @{
        question = "How do I implement a 2D player controller in Godot 4?"
        context  = @{
            engine_version    = "4.2"
            language          = "gdscript"
            selected_node_type = "CharacterBody2D"
            current_script    = ""
            extra             = @{}
        }
        top_k    = 5
    }

    Invoke-RagQuery -Name "C#-focused query" -Body @{
        question = "Show me how to handle input in a C# player controller."
        context  = @{
            engine_version    = "4.2"
            language          = "csharp"
            selected_node_type = ""
            current_script    = ""
            extra             = @{}
        }
        top_k    = 5
    }

    Invoke-RagQuery -Name "Shader-related query" -Body @{
        question = "How can I create a burning fire shader effect in Godot?"
        context  = @{
            engine_version    = "4.2"
            language          = "gdscript"
            selected_node_type = ""
            current_script    = ""
            extra             = @{}
        }
        top_k    = 5
    }

    Write-Host ""
    Write-Host "========== [SUCCESS] All RAG tests passed =========="
    Write-Host "[test] Full log: $logFile"
}
finally {
    if ($backend -and -not $backend.HasExited) {
        Write-Host "[test] Cleaning up..."
        Write-Host "[test] Stopping backend (PID=$backendPid)..."
        try {
            $backend.Kill()
            Write-Host "[test] Sent termination to backend."
        }
        catch { }
    }
    Stop-Transcript | Out-Null
}

