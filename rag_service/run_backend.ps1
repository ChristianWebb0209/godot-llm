Param(
  [string]$ListenHost = "0.0.0.0",
  [int]$ListenPort = 8000
)

$ErrorActionPreference = "Stop"

Write-Host "[run_backend] Starting Godot RAG backend..." -ForegroundColor Cyan

# Move to script directory (rag_service root)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "[run_backend] Working directory: $scriptDir" -ForegroundColor DarkCyan

# Activate venv if present
$venvActivate = Join-Path $scriptDir ".venv\Scripts\Activate.ps1"
if (Test-Path $venvActivate) {
  Write-Host "[run_backend] Activating venv at .venv" -ForegroundColor DarkCyan
  . $venvActivate
} else {
  Write-Warning "[run_backend] No venv found at .venv. Backend may fail if dependencies are missing."
}

Write-Host "[run_backend] Running: python -m uvicorn app.main:app --host $ListenHost --port $ListenPort --reload" -ForegroundColor DarkCyan
python -m uvicorn app.main:app --host $ListenHost --port $ListenPort --reload

