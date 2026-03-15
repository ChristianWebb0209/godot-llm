Param(
  [string]$ListenHost = "0.0.0.0",
  [int]$ListenPort = 8000,
  [switch]$Reload
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

# Default: no reload so the Godot plugin's streaming connection is not dropped when you save files.
$reloadArg = if ($Reload) { "--reload" } else { "" }
if (-not $Reload) {
  Write-Host "[run_backend] Running without --reload (use -Reload to enable auto-restart on file change)" -ForegroundColor DarkYellow
}
Write-Host "[run_backend] Running: python -m uvicorn app.main:app --host $ListenHost --port $ListenPort $reloadArg --log-level warning" -ForegroundColor DarkCyan
python -m uvicorn app.main:app --host $ListenHost --port $ListenPort $reloadArg --log-level warning

