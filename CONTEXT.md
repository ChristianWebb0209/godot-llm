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
    - `answer: str` – markdown answer text.
    - `snippets: List[SourceChunk]`:
      - `id`, `source_path`, `score`, `text_preview`, `metadata`.
    - `tool_calls: List[ToolCallResult]` (optional):
      - `tool_name: str`
      - `arguments: Dict[str, Any]`
      - `output: Any`
    - `context_usage: Dict` (optional):
      - `model: str`
      - `limit_tokens: int` (model context limit)
      - `estimated_prompt_tokens: int` (cheap local estimate)
      - `percent: float`

- `POST /query_stream`:
  - Same request body as `/query`.
  - Streams back the answer text as plain UTF‑8 chunks so the Godot dock can
    display it incrementally while the model is still generating.

- `POST /query_stream_with_tools`:
  - Streams answer text like `/query_stream`, then appends two sentinel blocks:
    - `__TOOL_CALLS__` followed by JSON array of tool calls (so the editor can run them).
    - `__USAGE__` followed by JSON `context_usage` (so the dock can update its UI).

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

> Implementation detail: if a collection already exists with a different
> embedding configuration, the backend reuses the existing collection and logs
> a warning, instead of crashing. To fully change embeddings, delete
> `chroma_db/` and re-run the indexers (see §4.3).

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

### 3.5 Tools & Orchestration (`rag_service/app/services/tools.py`)

- Backend tools are defined in `services/tools.py` as `ToolDef` objects with:
  - `name: str`
  - `description: str`
  - `parameters: Dict[str, Any]` – JSON-schema-like parameter definitions.
  - `handler(args: Dict[str, Any]) -> Any` – Python implementation.
- Current tools:
  - `search_docs`:
    - Searches the `docs` collection for relevant documentation.
    - Returns `id`, `path`, `score`, `metadata`, and `preview` text.
  - `search_project_code`:
    - Searches the `project_code` collection for relevant scripts/shaders.
    - Optional `language` filter: `"gdscript"`, `"csharp"`, `"gdshader"`.
    - Returns similar metadata + preview for each snippet.
- The function `get_openai_tools_payload()` converts these `ToolDef`s into the
  `tools=[...]` payload used with the OpenAI Responses API.
- The `/query` endpoint uses `_run_query_with_tools` to:
  - Run the initial RAG retrieval (docs + project_code).
  - Call the model with both the RAG context and the tool manifest.
  - Detect tool calls, execute them via `dispatch_tool_call`, and feed results
    back into the model for up to a small, fixed number of rounds.
- Today these tools operate only on collections (searching docs/code). Future
  work will add tools that plan **editor actions** (text patches, file
  creation, node renames) for the Godot plugin to execute.

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

#### 4.2.1 How the LLM should treat `docs` vs `project_code`

- The **`docs` collection** is scraped from the **official Godot 4.x manuals**. It is the
  **authoritative source** for engine behavior, APIs, and built-in classes.
- The **`project_code` collection** contains **example scripts and shaders** from various projects.
  These are meant as **patterns and inspiration**, not as canonical definitions of how the engine works.
- When there is any tension between what the docs say and what project code seems to imply:
  - The LLM should **prefer `docs`**.
  - Project code is still valuable for idioms, patterns, and end-to-end examples, but must not
    override the official documentation.

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
    - `Ask` button (icon-only; disabled + shows loading icon while streaming).
    - `Copy` button → copies parsed answer text to clipboard.
    - **Tools** checkbox: when checked, the dock uses `POST /query_stream_with_tools` so it can stream output *and* receive tool calls; tool calls with `execute_on_client: true` are run locally by `GodotAIEditorToolExecutor` (see §7.1).
    - Status label: short messages (`Ready`, `Sending...`, `Response received.`, `Nothing to copy.`, etc.).
  - Context usage indicator:
    - A compact label near the chat tabs shows estimated context usage (e.g. `Ctx: 2% (792/32768)`).
  - History tab:
    - Separate **History** tab (between Chat and Settings) shows SQLite-backed edit history + diffs and supports undo (see §7.2).
- Users can **resize** input vs output via the splitter.
- Copying output:
  - Uses `get_parsed_text()` to get plain text.
  - Uses `DisplayServer.clipboard_set(...)` to copy.
- The plugin passes `EditorInterface` into the dock via `set_editor_interface()` so the executor can open scenes, add nodes, and save.

### 7.1 Editor tools (client-side execution)

- Backend defines these tools in `services/tools.py`; handlers return `{ "execute_on_client": true, "action": "<name>", ... }` so the plugin knows to run them.
- **File / script tools** (executed in `editor_tool_executor.gd` via `FileAccess` and paths under `res://`):
  - **create_file**: `path`, `content`, optional `overwrite`.
  - **write_file**: `path`, `content` (overwrite entire file).
  - **apply_patch**: `path`, `old_string`, `new_string` (first occurrence replaced).
  - **create_script**: `path`, `language` (gdscript|csharp), optional `extends_class`, `initial_content`.
- **Scene / node tools** (require `EditorInterface`: open scene, get root, add child, save):
  - **create_node**: `scene_path`, `parent_path`, `node_type`, optional `node_name`. Adds a node of any Godot type to the given scene.
  - **set_node_property**: `scene_path`, `node_path`, `property_name`, `value` (JSON: number, string, bool, or array for Vector2/Vector3).
- Node tools run asynchronously (open scene → wait frame → get root → modify → save); the dock uses `execute_async()` and awaits each before updating status.

### 7.2 Edit history (SQLite) + Undo

- Backend stores structured history in a local SQLite DB:
  - `rag_service/ai_history.db`
- Tables (see also `todos/DB.md` for the intended model):
  - `edit_events`: timestamp, actor, trigger, prompt_hash, summary
  - `file_changes`: edit_id, file_path, change_type, unified diff, lines_added/lines_removed, old/new hashes, old_content/new_content
- Endpoints:
  - `POST /edit_events/create`: store an edit event + changes
  - `GET /edit_events/list?limit=...`: list history with per-file diffs and added/removed counts
  - `POST /edit_events/undo/{edit_id}`: returns tool calls to restore previous content via `write_file`
- Plugin behavior:
  - `editor_tool_executor.gd` returns an `edit_record` (old/new content) for file write/patch tools.
  - `ai_dock.gd` posts those records to `/edit_events/create`.
  - Undo in the History tab calls `/edit_events/undo/{id}` and executes the returned tool calls.

---

## 10. Context builder (efficient prompt assembly)

- Goal: only send what’s necessary; stable ordering; budget-aware trimming.
- Model context limits live in `rag_service/app/context_builder.py` (e.g. `gpt-4.1-mini` uses a conservative `32768`).
- The backend assembles ordered blocks with per-block budgets:
  - System instructions → Current task → Active file → Related files (structural proximity) → Recent edits (recency working set) → Errors → Retrieved knowledge → Optional extras
- Active file handling:
  - The plugin sends `context.current_script` and may send `context.extra.active_file_text`.
  - The plugin always sends `context.extra.project_root_abs` so the backend can read project files directly from disk (playground/local assumption).
  - If `active_file_text` is missing, the backend reads the active file from disk.
- Structural proximity:
  - Backend scans the active file text for referenced `res://...` paths and includes up to a few related files as a separate block.
- Recency working set:
  - Backend pulls recent diffs from SQLite and includes them as lightweight context.
- Compression vs truncation:
  - When a block is far over budget, the backend uses a cheap local “compression” fallback (key symbols + head/tail windows) instead of random truncation.
- Debugging:
  - Backend logs the full input payload sent to the LLM with `[llm_input] ...` (printing is made Windows-console-safe).

---

## 8. Testing & Diagnostics Summary

- `run_backend.ps1`:
  - Start/stop backend with proper venv activation.
- `run_tools.ps1`:
  - Single entrypoint for:
    - `scrape_docs`, `index_docs`, `analyze_project`.
    - `chroma_status`, `rag_tests`, `chroma_visualize`.
- `scripts/testing/chroma-status.ps1`:
  - Windows-friendly status script for collections + sample docs.
- `scripts/testing/chroma_visualize.py`:
  - Browser-based viewer for documents and metadata.
- `scripts/testing/run_e2e_rag_tests.ps1`:
  - End-to-end test harness:
    - Validates OpenAI key/quota (if configured).
    - Spins up backend.
    - Hits `/query` with representative questions.
    - Logs everything to `scripts/testing/logs/` (if configured there).
- `scripts/testing/run_tool_usage_tests.py` + `run_tool_usage_tests.ps1`:
  - Sends a small battery of prompts to `/query` to verify that:
    - Explicit tool usage instructions (e.g. “use `search_docs`”) result in
      corresponding tool calls.
    - The model can also decide to call tools on its own for certain queries.

---

## 9. Open Questions / Future Work (for Future LLMs)

- **Editor tools** are implemented: create_file, write_file, apply_patch, create_script, create_node, set_node_property. Future work could add Undo/Redo integration, or tools that operate on the “current” script/scene (infer from editor state).
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

