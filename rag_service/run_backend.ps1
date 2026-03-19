Param(
  [string]$ListenHost = "0.0.0.0",
  [int]$ListenPort = 8000,
  [switch]$Reload
)

$ErrorActionPreference = "Stop"

# Go to script dir (rag_service)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "[run_backend] Starting in $scriptDir"

# -----------------------------
# Load .env (same dir)
# -----------------------------
$envFile = Join-Path $scriptDir ".env"

if (!(Test-Path $envFile)) {
  Write-Error ".env not found in rag_service"
  exit 1
}

Get-Content $envFile | ForEach-Object {
  # Skip blank lines and comments
  if ($_ -match "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$") {
    $key   = $matches[1]
    $value = $matches[2].Trim().Trim('"').Trim("'")
    [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
  }
}

if (-not $env:OPENAI_API_KEY) {
  Write-Error "OPENAI_API_KEY missing from .env"
  exit 1
}

# -----------------------------
# Use venv python (repo root)
# -----------------------------
$python = [System.IO.Path]::GetFullPath("$scriptDir\..\\.venv\Scripts\python.exe")

if (!(Test-Path $python)) {
  Write-Error ".venv python not found at: $python"
  exit 1
}

# -----------------------------
# Run
# -----------------------------
$uvicornArgs = @(
  "-m", "uvicorn", "app.main:app",
  "--host", $ListenHost,
  "--port", $ListenPort,
  "--log-level", "info"
)

if ($Reload) {
  $uvicornArgs += "--reload"
}

& $python @uvicornArgs