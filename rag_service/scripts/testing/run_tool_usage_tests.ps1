<#
run_tool_usage_tests.ps1

Run a small battery of tests against the RAG backend to verify that
backend tools (e.g. search_docs, search_project_code) are being used
correctly by the LLM.

Usage:
  cd C:\Github\godot-llm\rag_service
  .\scripts\testing\run_tool_usage_tests.ps1

Assumptions:
  - The Python venv exists at .venv and contains all dependencies.
  - The backend is already running (e.g. via .\run_backend.ps1).
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path "$ScriptDir\.."

Set-Location $RepoRoot

if (Test-Path ".\.venv\Scripts\Activate.ps1") {
    . .\.venv\Scripts\Activate.ps1
}

Write-Host "Running tool usage tests against RAG backend..."
python .\scripts\testing\run_tool_usage_tests.py

