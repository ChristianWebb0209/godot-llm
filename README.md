## Godot LLM Assistant – Quick Guide

This repo contains:

- `rag_service/` – FastAPI RAG backend + tools (scraper, project analyzer, indexers, tests).
- `godot_plugin/addons/godot_ai_assistant/` – Godot editor plugin.

It does NOT contain:
- godot_knowledge_base, required for RAG functionality. I am not including it because the data used to create it is not open source.

A lot of the scripts are .ps1, so this repo is meant for windows. Converting these to bash wouldn't be too hard, though.

## Linting

Since LLMs aren't great at writing .gd code, it is recommended to build the latest godot stable version, and set up a script to lint (see gdlint.ps1), then set an LLM rule to lint every time they modify a .gd file.

---

## 1. Python & venv (Python 3.11)

```powershell
cd C:\Github\godot-llm\rag_service

# Create venv
py -3.11 -m venv .venv

# Activate venv
.\.venv\Scripts\Activate.ps1

# Install / update deps
python -m pip install --upgrade pip
python -m pip install -r .\requirements.txt
```

Re-activate later:

```powershell
cd C:\Github\godot-llm\rag_service
.\.venv\Scripts\Activate.ps1
```

---

## 2. Run the RAG backend

With venv active:

```powershell
cd C:\Github\godot-llm\rag_service
.\run_backend.ps1    # activates venv (if present) and runs uvicorn
```

You can override host/port if you want:

```powershell
.\run_backend.ps1 -ListenHost "127.0.0.1" -ListenPort 9000
```

Health check:

- `http://127.0.0.1:8000/health`

Env config (in `rag_service/.env`):

- `OPENAI_API_KEY`
- `OPENAI_MODEL` (e.g. `gpt-4.1-mini`)
- `OPENAI_EMBED_MODEL` (e.g. `text-embedding-3-small`)
- `OPENAI_BASE_URL` (optional)

The backend:

- Uses **ChromaDB** (`chroma_db/`) as the vector store.
- Pulls from:
  - `docs` collection – scraped **official Godot 4.x docs** (authoritative for APIs/engine behavior).
  - `project_code` collection – example scripts/shaders from projects (patterns, not canonical).
- Returns verbose answers with a **Reasoning** section and supporting snippets.

HTTP endpoints:

- `GET /health` → `{ "status": "ok" }`
- `POST /query`
  - Request: `QueryRequest` (see `CONTEXT.md` for full schema).
  - Response:
    - `answer: str` – markdown answer text.
    - `snippets: List[SourceChunk]` – docs + code chunks used.
    - `tool_calls: List[ToolCallResult]` – optional record of backend tools used.
- `POST /query_stream`
  - Same request body as `/query`.
  - Streams back the answer text as plain UTF‑8 chunks so the Godot dock can display it incrementally.

---

## 3. Scrape Godot docs → `godot_knowledge_base/docs/4.6`

From `rag_service/` with venv active:

```powershell
cd C:\Github\godot-llm\rag_service

# Small test crawl
.\run_tools.ps1 scrape_docs `
  --base-url https://docs.godotengine.org/en/stable/ `
  --output-root ..\godot_knowledge_base\docs\4.6 `
  --max-pages 10

# Full crawl (remove max-pages)
.\run_tools.ps1 scrape_docs `
  --base-url https://docs.godotengine.org/en/stable/ `
  --output-root ..\godot_knowledge_base\docs\4.6
```

By default the scraper **resumes** (skips pages whose `.md` already exists). Use `--no-resume` to overwrite all pages.

---

## 4. Index docs into ChromaDB

From `rag_service/tools/docs-parser` with venv active:

```powershell
# Dry run: show what would be indexed
.\run_tools.ps1 index_docs --dry-run

# Actual index: rebuilds Chroma 'docs' collection from scratch
.\run_tools.ps1 index_docs
```

Docs are stored with metadata:

- `path` – relative under `godot_knowledge_base/docs/4.6`.
- `engine_version` – e.g. `4.6`.

---

## 5. Analyze & index Godot projects (code)

`analyze_project.py` does:

- Parse a Godot project (`project.godot`, `.tscn`, `.gd`, `.cs`, `.gdshader`).
- Compute **importance** for each script/shader.
- Copy important ones to `godot_knowledge_base/code/demos/<slug>/...`.
- Index them into Chroma `project_code` with metadata:
  - `project_id`, `path`, `language`, `tags`, `importance`.

From `rag_service/tools/project-parser` with venv active:

```powershell
cd C:\Github\godot-llm\rag_service
# Interactive mode (recommended)
.\run_tools.ps1 analyze_project
```

Interactive flow:

- Uses default output root:
  - `..\..\..\godot_knowledge_base\code\demos`
- Optionally **cleans** that folder first.
- Lets you set `importance_threshold` (default `0.3`).
- Then repeatedly:
  - `Project root (or 'exit'): C:\Users\you\Desktop\SomeGodotProject`

Single project:

```powershell
.\run_tools.ps1 analyze_project `
  --source-root "C:\path\to\GodotProject" `
  --importance-threshold 0.3 `
  [--output-root "C:\Github\godot-llm\godot_knowledge_base\code\demos"] `
  [--clean]
```

Batch directory:

```powershell
.\run_tools.ps1 analyze_project `
  --projects-root "C:\path\to\many\projects" `
  --importance-threshold 0.3 `
  [--output-root "C:\Github\godot-llm\godot_knowledge_base\code\demos"] `
  [--clean]
```

Each run:

- Logs to stdout only (no per-run log files).
- Writes `PROJECT.md` per project under `code/demos/<slug>/`.
- Indexes selected scripts/shaders into Chroma `project_code`.

---

## 6. ChromaDB status & RAG test harness

From `rag_service/tools/testing` with venv active:

```powershell
cd C:\Github\godot-llm\rag_service
```

### 6.1. Inspect ChromaDB (`chroma-status.sh`)

```bash
.\run_tools.ps1 chroma_status
```

Shows (color coded):

- DB root path.
- Collections (e.g. `docs`, `project_code`) and document counts.
- Up to 3 sample entries per collection:
  - `id`, `path`, `language`, `importance`, `tags`, and a short preview.

### 6.2. End-to-end RAG tests (`run_e2e_rag_tests.sh`)

```bash
.\run_tools.ps1 rag_tests
```

This script:

- Activates venv.
- Validates `OPENAI_API_KEY` by making a small chat call (detects invalid key / no credits).
- Starts the backend (uvicorn) in the background.
- Waits for `/health` to return 200.
- Runs a series of `/query` tests via `curl`:
  - GDScript movement.
  - C# input handling.
  - Shader-related query.
- Fails loudly (with logs) on any non‑200 or curl error.
- Logs everything to:
  - `rag_service/tools/testing/logs/run_e2e_rag_tests_<timestamp>.log`

### 6.3. Visualize ChromaDB (`chroma_visualize.py`)

```powershell
cd C:\Github\godot-llm\rag_service
.\run_tools.ps1 chroma_visualize
```

Then open in browser:

- `http://127.0.0.1:8001/` → list collections and counts.
- Click a collection (e.g. `docs`, `project_code`) to see:
  - IDs.
  - Metadata (`path`, `language`, `importance`, `tags`).
  - Text preview (first few lines of the stored document).

---

## 7. Godot editor plugin

Plugin lives in:

- `godot_plugin/addons/godot_ai_assistant/`

To use in a Godot project:

```powershell
# Example project root
cd C:\Games\MyGodotProject
mkdir addons

# Junction to stay in sync with repo (requires admin)
mklink /J `
  "addons\godot_ai_assistant" `
  "C:\Github\godot-llm\godot_plugin\addons\godot_ai_assistant"
```

Then:

1. Enable plugin:
   - `Project > Project Settings > Plugins` → enable **Godot AI Assistant**.
2. Make sure backend is running at `http://127.0.0.1:8000`.
3. Open **AI Assistant** dock and ask questions.

The dock sends `/query` with:

- Engine version.
- Preferred language (`gdscript` / `csharp`).
- (Future) richer editor context.

---

## 8. Git hygiene (short)

- `.gitignore`:
  - Ignores `godot/` engine clone.
  - Tracks only `godot_plugin/addons/godot_ai_assistant` from the plugin tree.
  - Ignores `rag_service/.venv` and generated corpora (`godot_knowledge_base/**`, `chroma_db/**`).

Typical commit:

```powershell
cd C:\Github\godot-llm
git status
git add rag_service godot_plugin godot_knowledge_base README.md
git commit -m "Update RAG pipeline and plugin"
```

