## Project Context for Future LLMs

This file is the **single source of truth** for how the **Godot LLM Assistant** works: architecture, tools, conventions, and important paths. Future LLMs should read this before making changes.

---

## 1. High-Level Vision

- **Goal**: An AI-native assistant *inside Godot* that:
  - Lives as a **Godot editor plugin**.
  - Talks to a **RAG + LLM backend**.
  - Understands **Godot 4.x** docs, patterns, and **real project code** in:
    - GDScript (`.gd`)
    - C# (`.cs`)
    - Godot shaders (`.gdshader`)
- Current focus:
  - A robust **RAG pipeline**:
    - Scrape + index official Godot docs.
    - Ingest many GB of Godot projects (including large C#/shader-heavy games).
    - Score and tag scripts by **importance** and **tags**.
    - Retrieve a small set of **high-signal examples** per query.
  - Editor plugin is a **question/answer dock** only (no automatic edits yet).

---

## 2. Repo Layout (Key Paths)

- `rag_service/` – Python 3.11 backend + tooling.
- `godot_plugin/addons/godot_ai_assistant/` – Godot editor plugin.
- `godot_knowledge_base/` – Scraped docs + curated code.
- `chroma_db/` – Local ChromaDB store (vector DB for docs + code).

Important subpaths:

- Backend:
  - `rag_service/app/main.py` – FastAPI + RAG.
  - `rag_service/run_backend.ps1` – start backend.
  - `rag_service/run_tools.ps1` – unified launcher for tools.
- Docs pipeline:
  - `rag_service/tools/docs-parser/scrape_godot_docs.py` – crawler → markdown.
  - `rag_service/tools/docs-parser/index_docs.py` – index markdown → Chroma `docs`.
  - `godot_knowledge_base/docs/4.6/**` – scraped docs.
- Project pipeline:
  - `rag_service/tools/project-parser/analyze_project.py` – analyze/import projects.
  - `godot_knowledge_base/code/demos/<slug>/` – selected important scripts/shaders.
  - Chroma `project_code` collection – indexed project code.
- Testing/inspection:
  - `rag_service/tools/testing/run_e2e_rag_tests.sh` – end-to-end RAG tests.
  - `rag_service/tools/testing/chroma-status.sh` – CLI status for Chroma.
  - `rag_service/tools/testing/chroma_visualize.py` – web UI for Chroma.

---

## 3. Backend & RAG (`rag_service/app/main.py`)

### 3.1 FastAPI Endpoints

- `GET /health`:
  - Returns `{ "status": "ok" }`.
  - Used by Godot plugin + test scripts to confirm backend is up.

- `POST /query`:
  - Request model:
    - `question: str`.
    - `context` (optional):
      - `engine_version: Optional[str]`.
      - `language: Optional[str]` – `"gdscript"` or `"csharp"`.
      - `selected_node_type: Optional[str]`.
      - `current_script: Optional[str]`.
      - `extra: Dict[str, Any]`.
    - `top_k: int = 5`.
  - Response model:
    - `answer: str`.
    - `snippets: List[SourceChunk]`:
      - `id`, `source_path`, `score`, `text_preview`, `metadata`.

### 3.2 Environment & OpenAI

- `.env` in `rag_service` is loaded via `python-dotenv`:
  - `OPENAI_API_KEY`
  - `OPENAI_MODEL` (default `"gpt-4.1-mini"`)
  - `OPENAI_EMBED_MODEL` (default `"text-embedding-3-small"`)
  - `OPENAI_BASE_URL` (optional)
- `get_openai_client()`:
  - Returns an `OpenAI` client if `OPENAI_API_KEY` is set.
  - Returns `None` otherwise (backend falls back to a plain-text explanation).

### 3.3 ChromaDB Setup (Shared with Tools)

- Collections:
  - `docs` – scraped markdown docs.
  - `project_code` – important scripts/shaders from projects.
- Embeddings:
  - If `OPENAI_API_KEY` is set:
    - Use `OpenAIEmbeddingFunction` with `OPENAI_EMBED_MODEL` for both collections.
  - If not:
    - Fall back to Chroma’s defaults (not recommended for production).

### 3.4 Retrieval Strategy

- Docs retrieval (`_collect_top_docs`):
  - Queries `docs` collection with `query_texts=[question]`, `n_results=top_k`.
  - Wraps results as `SourceChunk` with path + metadata.

- Code retrieval (`_collect_code_results`):
  - Queries `project_code` in **importance tiers**:
    - Tier 1: `importance >= 0.6`.
    - Tier 2: `importance >= 0.3`.
    - Tier 3: `importance >= 0.0`.
  - Filters by `language` if provided.
  - Dedupes IDs across tiers.
  - Stops once `top_k` snippets gathered.

- Obscure topic heuristic:
  - If `len(code_snippets) < max(1, top_k // 3)`:
    - `is_obscure = True`.
    - LLM is told that this is a more niche area, so lower-importance code was used.

- Answer generation (`_call_llm_with_rag`):
  - If OpenAI client exists:
    - System prompt instructs:
      - Use only provided docs/code.
      - Prefer higher-importance code when multiple snippets match.
      - Explain reasoning and reference paths + tags.
      - Use user’s preferred language for code examples.
    - User message includes:
      - Question, preferred language.
      - Obscure flag (if true).
      - `=== Documentation Context ===` with `[DOC] path=... meta=...`.
      - `=== Project Code Context ===` with `[CODE] path=... meta=...`.
    - LLM asked to respond with:
      1. Concise answer.
      2. `Reasoning` section.
      3. Code examples in preferred language.
  - If no OpenAI client:
    - Returns a verbose string summarizing:
      - Question.
      - Preferred language.
      - Relevant docs (paths).
      - Relevant code snippets (paths, importance, tags).
      - Obscure note (if applicable).

---

## 4. ChromaDB Collections & Indexing

### 4.1 Docs Collection (`docs`)

- Created and managed by `index_docs.py`.
- Always **rebuilt from scratch** on each `index_docs` run:
  - Existing `docs` collection is deleted.
  - New one is created with the current embedding function (OpenAI if available).
- Documents:
  - `id` = relative path under `docs_root` (e.g. `classes/class_node.md`).
  - `document` = full markdown file text.
  - `metadata`:
    - `path`: same as `id`.
    - `engine_version`: inferred from `docs_root` (e.g. `"4.6"`).

### 4.2 Project Code Collection (`project_code`)

- Created/updated by `analyze_project.py` (`index_in_chromadb`).
- On each ingest:
  - Loads `.env` to configure embeddings.
  - Reuses or creates `project_code` collection:
    - Prefer OpenAI embedding function if available.
    - If the collection already exists with a different embedding, logs a warning and uses the existing configuration (instead of crashing).
- Documents:
  - `id` = `"<project_slug>:<rel_path>"`.
  - `document` = full source code (script or shader).
  - `metadata`:
    - `project_id` – slug.
    - `path` – relative path (e.g. `src/Core/Nodes/Player/Player.gd`).
    - `language` – `"gdscript"`, `"csharp"`, `"gdshader"`.
    - `importance` – float.
    - `tags` – optional non-empty list if tags exist.

### 4.3 Clean Reset Procedure (Important)

If you ever change embedding config or see conflicts like “embedding function conflict: new: openai vs persisted: default”:

1. Stop backend.
2. Delete `chroma_db/`:

   ```powershell
   cd C:\Github\godot-llm\rag_service
   Remove-Item -Recurse -Force .\chroma_db
   ```

3. Re-run:
   - `run_tools.ps1 index_docs` → rebuild `docs`.
   - `run_tools.ps1 analyze_project ...` → rebuild `project_code`.

Both backend and tools now share identical embedding configuration logic via `.env`.

---

## 5. Docs Pipeline

### 5.1 Scraper (`scrape_godot_docs.py`)

- Inputs:
  - `--base-url` (default Godot stable docs).
  - `--output-root` (default `../godot_knowledge_base/docs/4.6`).
  - `--max-pages` (optional test limit).
  - `--no-resume` (optional; by default resume is **enabled**).
- Behavior:
  - BFS crawl starting at `base_url`.
  - Uses `is_docs_url` to ensure:
    - Same host + under base path.
    - Only HTML or directory-like paths.
    - Skips images/CSS/JS/fonts.
  - Writes out each page to `.md` via `page_to_markdown`:
    - YAML-style header with:
      - `title`.
      - `source_url`.
      - `sections` (H2s) + optional `subsections`.
    - Body markdown from the main docs content.
  - `resume` handling:
    - For each URL → output path via `path_from_url`.
    - If `resume=True` and file exists:
      - Prints `[scrape] SKIP (already exists): <path>`.
      - Still enqueues outgoing links from that page.

### 5.2 Indexing (`index_docs.py`)

- Uses `load_dotenv()` so `OPENAI_*` is visible.
- Deletes old `docs` collection and recreates it each time.
- Indexing:
  - Walks `docs_root` for `*.md`.
  - Reads file text.
  - Computes relative path + `engine_version`.
  - Adds batched docs (default batch size 64):
    - `ids`, `documents`, `metadatas`.

---

## 6. Project Analyzer & Importance Scoring

### 6.1 CLI Modes (`analyze_project.py`)

- Single project:

  ```powershell
  .\run_tools.ps1 analyze_project --source-root "C:\path\to\Project"
  ```

- Batch folder:

  ```powershell
  .\run_tools.ps1 analyze_project --projects-root "C:\path\to\ManyProjects"
  ```

- Interactive:

  ```powershell
  .\run_tools.ps1 analyze_project
  ```

  - If `C:\Users\caweb\Desktop\godot-demo-projects` exists:
    - Pressing Enter uses that folder as default and scans recursively for projects.
  - Otherwise asks you for specific project roots.

In **all** modes:

- If the provided root folder does **not** contain `project.godot` directly:
  - Script scans recursively with `rglob("project.godot")`.
  - Treats each parent folder as a project root.
  - Logs if no projects are found.

### 6.2 What It Parses

- Confirms `project.godot` under each project root.
- `project.godot`:
  - `run/main_scene`.
  - `autoload` sections.
- Scenes (`*.tscn`):
  - Root node type (first node without `parent`).
  - Attached scripts via `ExtResource` (supports `.gd` and `.cs`).
  - Instanced sub-scenes via `instance=ExtResource(...)`.
- Scripts:
  - `.gd`:
    - `extends` line, LOC, feature flags, path tags.
  - `.cs`:
    - `class Foo : Base` detection of base class.
    - C#-style signals, input, callbacks, physics.
  - `.gdshader`:
    - Language `"gdshader"`, LOC and path for tagging and importance.

### 6.3 Importance Threshold

- Default `importance_threshold = 0.3`.
- Can be set via CLI or interactively.
- Only scripts/shaders with `importance >= threshold` are:
  - Copied into `godot_knowledge_base/code/demos/<slug>/`.
  - Indexed into Chroma `project_code`.

---

## 7. Godot Plugin Dock & Copy UX

- Plugin dock:
  - Question label + a `VSplitContainer`:
    - Top: `TextEdit` for question.
    - Bottom: `RichTextLabel` for answer/snippets.
  - Control row:
    - `Ask` button.
    - `Copy` button → copies parsed answer text to clipboard.
    - Status label: short messages (`Ready`, `Sending...`, `Response received.`, `Nothing to copy.`, etc.).
- Users can **resize** input vs output via the splitter.
- Copying output:
  - Uses `get_parsed_text()` to get plain text.
  - Uses `DisplayServer.clipboard_set(...)` to copy.

---

## 8. Testing & Diagnostics Summary

- `run_backend.ps1`:
  - Start/stop backend with proper venv activation.
- `run_tools.ps1`:
  - Single entrypoint for:
    - `scrape_docs`, `index_docs`, `analyze_project`.
    - `chroma_status`, `rag_tests`, `chroma_visualize`.
- `chroma-status.sh`:
  - Quick status of collections + sample docs.
- `chroma_visualize.py`:
  - Browser-based viewer for documents and metadata.
- `run_e2e_rag_tests.sh`:
  - End-to-end test harness:
    - Validates OpenAI key/quota.
    - Spins up backend.
    - Hits `/query` with representative questions.
    - Logs everything to `tools/testing/logs/`.

---

## 9. Open Questions / Future Work (for Future LLMs)

- **Editor integration for edits**:
  - Current system is read-only; future work should define a **very small, safe set of editor “tools”** for the LLM.
  - Candidate tools:
    - Apply text patch to current script.
    - Create a script file from a template.
    - Add/rename nodes in current scene using Undo/Redo.
- **Better tagging / roles**:
  - Expand tags beyond basic player/enemy/UI to cover common patterns (camera, inventory, dialogue, VFX).
- **Shader-specific insights**:
  - Currently treat `.gdshader` mostly as text examples.
  - Future: parse and categorize shaders by function (post-process, material, UI effect, etc.).
- **Per-project normalization**:
  - Consider normalizing importance scores so every project yields a healthy mix of top/mid-tier examples.

Future LLMs working on this repo should **respect this context** and maintain consistency with:

- The Chroma schema (`docs` and `project_code` metadata).
- The importance tiers for code retrieval.
- The Godot plugin’s data contract for `/query` (`QueryRequest`, `QueryResponse`).

