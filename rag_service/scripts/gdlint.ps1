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
$RagServiceRoot = Resolve-Path "$ScriptDir\.."
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

# If every file is under godot_plugin, run from plugin project for full type checking.
$AllUnderPlugin = $true
$RelativePaths = @()
foreach ($p in $ResolvedFiles) {
    if ($p.StartsWith($PluginRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $p.Substring($PluginRoot.Length).TrimStart('\', '/')
        $RelativePaths += $rel
    } else {
        $AllUnderPlugin = $false
        break
    }
}

$OutFile = Join-Path $RagServiceRoot "gdscript_errors.txt"

# Always pass a project path when the plugin project exists so Godot never shows "Couldn't detect..." (ALERT popup).
$ProjectPath = $null
$projectGodot = Join-Path $PluginRoot "project.godot"
if (Test-Path $projectGodot) {
    $ProjectPath = (Resolve-Path $PluginRoot).Path
}

# When --path is set, Godot prefers paths relative to the project root (e.g. addons/godot_ai_assistant/file.gd).
$FilesToCheck = @()
foreach ($p in $ResolvedFiles) {
    if ($ProjectPath -and $p.StartsWith($ProjectPath, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $p.Substring($ProjectPath.Length).TrimStart('\', '/').Replace('\', '/')
        $FilesToCheck += $rel
    } else {
        $FilesToCheck += $p
    }
}

if ($ProjectPath) {
    Write-Host "Running Godot headless linter (project: godot_plugin) on:" $FilesToCheck
} else {
    Write-Host "Running Godot headless linter on:" $FilesToCheck
}

Write-Host "RepoRoot:" $RepoRoot
Write-Host "PluginRoot:" $PluginRoot
Write-Host "ProjectPath:" $ProjectPath
Write-Host "GodotBin:" $GodotBin

# Editor + headless: linter runs in editor runtime; --editor avoids startup ambiguity / popup.
$godotArgs = @("--headless", "--editor")
if ($ProjectPath) {
    $godotArgs += @("--path", $ProjectPath)
}
$godotArgs += @("--check-only") + $FilesToCheck

$output = & $GodotBin $godotArgs 2>&1
$exitCode = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }

$output | Set-Content -Path $OutFile
$output | Write-Host
Write-Host ""
Write-Host "gdlint: results written to gdscript_errors.txt"
if ($exitCode -ne 0) {
    Write-Host "gdlint: Godot reported errors (exit code $exitCode)"
    exit $exitCode
}