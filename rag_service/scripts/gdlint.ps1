<#
gdlint.ps1

Run the Godot headless CLI linter on one or more GDScript files.
Runs Godot with the plugin project (godot_plugin) when files are under it,
so full type inference and linting apply.

Usage:
  cd C:\Github\godot-llm\rag_service
  .\scripts\gdlint.ps1 -Files "..\godot_plugin\addons\godot_ai_assistant\ai_dock.gd"

Behavior:
  - Looks for a local Godot editor binary under ../godot/bin.
  - If not found, falls back to 'godot' on PATH.
  - If all files are under repo/godot_plugin, runs Godot with --path godot_plugin
    so the project is loaded and type checking is strict.
  - Writes all linter output to gdscript_errors.txt in rag_service.
  - Exits with Godot's exit code so CI/editors can detect failures.
#>

param(
    [Parameter(Mandatory=$true)]
    [string[]]$Files
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RagServiceRoot = (Resolve-Path "$ScriptDir\..").Path
$RepoRoot = (Get-Item $RagServiceRoot).Parent.FullName
$PluginRoot = Join-Path $RepoRoot "godot_plugin"
$GodotBin = Join-Path $RepoRoot "godot\bin\godot.windows.editor.x86_64.exe"

if (!(Test-Path $GodotBin)) {
    $GodotBin = "godot"
}

# Resolve file paths relative to rag_service (typical CWD when invoking this script).
$ResolvedFiles = @()
foreach ($f in $Files) {
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RagServiceRoot $f))
    $ResolvedFiles += $fullPath
}

$OurPid = $PID
$OutFilePid = Join-Path ([System.IO.Path]::GetTempPath()) ("gdscript_errors_" + $OurPid + ".txt")

# Always pass a project path when the plugin project exists so Godot never shows "Couldn't detect..." (ALERT popup).
$ProjectPath = $null
$projectGodot = Join-Path $PluginRoot "project.godot"
if (Test-Path $projectGodot) {
    $ProjectPath = (Resolve-Path $PluginRoot).Path
}

# Convert absolute paths to the form Godot expects for --script:
# - If project is known and file is under it, use a project-relative path (e.g. addons/foo/bar.gd).
# - Otherwise, pass the absolute path.
$ScriptsToCheck = @()
foreach ($p in $ResolvedFiles) {
    if ($ProjectPath -and $p.StartsWith($ProjectPath, [StringComparison]::OrdinalIgnoreCase)) {
        $ScriptsToCheck += $p.Substring($ProjectPath.Length).TrimStart('\', '/').Replace('\', '/')
    } else {
        $ScriptsToCheck += $p
    }
}

if ($ProjectPath) {
    Write-Host "Running Godot script parse check (project: godot_plugin) on:" $ScriptsToCheck
} else {
    Write-Host "Running Godot script parse check on:" $ScriptsToCheck
}

# Godot writes to the console in a way PowerShell can't reliably capture into variables,
# so we redirect directly to the output file via cmd.exe.
try {
    Set-Content -Path $OutFilePid -Value "" -Encoding utf8 -Force
} catch {
    Write-Host "gdlint: failed to clear output file:" $_
}

foreach ($scriptPath in $ScriptsToCheck) {
    Add-Content -Path $OutFilePid -Value ("=== " + $scriptPath + " ===") -Encoding utf8

    $cmdParts = @(
        "`"$GodotBin`"",
        "--headless",
        "--editor"
    )
    if ($ProjectPath) {
        $cmdParts += @("--path", "`"$ProjectPath`"")
    }
    $cmdParts += @("--script", "`"$scriptPath`"", "--check-only")

    $cmdLine = ($cmdParts -join " ") + " >> `"$OutFilePid`" 2>&1"
    & cmd /c $cmdLine | Out-Null
    Add-Content -Path $OutFilePid -Value "" -Encoding utf8
}

if (-not (Test-Path $OutFilePid)) {
    Write-Host "gdlint: warning: output file was not created:" $OutFilePid
    exit 1
}

$raw = ""
try {
    $raw = Get-Content -Path $OutFilePid -Raw -ErrorAction SilentlyContinue
} catch {
    $raw = ""
}

# Output the Godot output to console so VS Code problemMatcher can parse it
Write-Output $raw

# Clean up temporary output file
try {
    Remove-Item -Path $OutFilePid -Force -ErrorAction SilentlyContinue
} catch {}

if ($raw -match "SCRIPT ERROR:" -or $raw -match "Parse Error:" -or $raw -match "Failed to load script") {
    Write-Host "gdlint: issues found"
    exit 1
}

Write-Host "gdlint: ok"