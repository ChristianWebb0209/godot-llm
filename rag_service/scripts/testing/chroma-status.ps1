param()

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ragServiceDir = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$dbRoot = Join-Path $ragServiceDir 'chroma_db'

$logDir = Join-Path $scriptDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "chroma_status_${timestamp}.log"

Start-Transcript -Path $logFile -Force | Out-Null

Write-Host ""
Write-Host "========== [STEP] Paths and environment =========="
Write-Host "[info] SCRIPT_DIR      = $scriptDir"
Write-Host "[info] RAG_SERVICE_DIR = $ragServiceDir"
Write-Host "[info] DB_ROOT         = $dbRoot"

if (-not (Test-Path $dbRoot)) {
    Write-Warning "ChromaDB root does not exist yet: $dbRoot"
    Write-Warning "You may need to run the docs indexer and project analyzer first."
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
Write-Host "========== [STEP] Inspecting ChromaDB =========="

$py = @"
import os
from pathlib import Path

import chromadb

db_root = Path(r"$dbRoot")
print(f"[info] Using DB root: {db_root}")

if not db_root.exists():
    print("[warn] DB root does not exist yet. No collections to show.")
    raise SystemExit(0)

client = chromadb.PersistentClient(path=str(db_root))
collections = client.list_collections()

if not collections:
    print("[warn] No collections found in ChromaDB.")
    raise SystemExit(0)

print(f"[info] Found {len(collections)} collection(s):")

for coll in collections:
    name = coll.name
    try:
        count = coll.count()
    except Exception as e:
        print(f"  [error] Collection '{name}': failed to count documents: {e}")
        continue

    print(f"  {name} - {count} document(s)")

    try:
        peek = coll.peek()
    except Exception as e:
        print(f"    [error] Failed to peek into '{name}': {e}")
        continue

    ids = (peek.get("ids") or [[]])[0]
    docs = (peek.get("documents") or [[]])[0]
    metas = (peek.get("metadatas") or [[]])[0]

    if not ids:
        print("    (no sample documents)")
        continue

    print("    Sample entries (up to 3):")
    for i, doc_id in enumerate(ids[:3]):
        meta = metas[i] if i < len(metas) and metas[i] else {}
        path = meta.get("path", "")
        importance = meta.get("importance")
        lang = meta.get("language")
        tags = meta.get("tags")

        print(f"      - id: {doc_id}")
        if path:
            print(f"        path: {path}")
        if lang:
            print(f"        language: {lang}")
        if importance is not None:
            print(f"        importance: {importance}")
        if tags:
            print(f"        tags: {tags}")

        if i < len(docs) and docs[i]:
            preview = str(docs[i]).splitlines()
            snippet = "\n".join(preview[:3])
            print("        preview:")
            for line in snippet.splitlines():
                print(f"          {line}")

print("[ok] ChromaDB status inspection complete.")
"@

$py | & $pythonExe - | Out-Host

Write-Host ""
Write-Host "[ok] ChromaDB status printed above. Full log: $logFile"

Stop-Transcript | Out-Null

