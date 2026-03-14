## Project Context for Future LLMs

This file is the **single source of truth** for how the **Godot LLM Assistant** works: architecture, tools, conventions, and important paths. **Read this before making changes.**

---

## Quick reference for future agents

- **Change a tool (add/rename/parameters)**  
  `rag_service/app/services/tools.py`: edit `ToolDef` in `get_registered_tools()` and the handler; update `main.py` system prompt if the LLM must use it differently. Plugin: `godot_plugin/addons/godot_ai_assistant/editor_tool_executor.gd` for execute_on_client actions.

- **Change what the LLM sees (context / tools)**  
  `rag_service/app/main.py`: `_run_query_with_tools` (system prompt, user blocks, tool payload). `rag_service/app/context_builder.py`: block order and budgets.

- **Change plugin UI (tabs, chat, diff, history)**  
  `godot_plugin/addons/godot_ai_assistant/ai_dock.gd` (logic) and `ai_dock.tscn` (scene). Tab selection uses **child node name** (e.g. `History`, `Settings`), not tab index.

- **Edit History data**  
  Backend: `rag_service/app/db.py` (edit_events, file_changes); DB file `rag_service/ai_history.db`. Plugin: Edit History tab uses `GET /edit_events/list?limit=500` and `GET /edit_events/{id}`.

- **Plugin not loading**  
  If the dock does not appear: check Godot Output for parse/script errors. Common causes: wrong node path in @onready (use `get_node_or_null()` in `_ready()` for optional nodes), or GDScript/Godot 4 API misuse (see §12). Open the project from the folder that contains `project.godot` (e.g. `godot_plugin`), not the parent repo root.

- **read_file / lint_file**  
  When the plugin sends `context.extra.project_root_abs`, the backend runs `read_file` on the server and returns file content to the LLM. `lint_file` is editor-only: plugin runs `--check-only` and shows output in chat; the LLM does not get that output in the same turn.

- **Run backend**  
  From `rag_service/`: `.\run_backend.ps1` (or `uvicorn app.main:app --reload`). Default URL `http://127.0.0.1:8000`; plugin uses Settings or `rag_service_url`.

- **Quick test**  
  Backend: `GET http://127.0.0.1:8000/health` → `{ "status": "ok" }`. Plugin: enable Tools, ask something that triggers read_file or a file edit; check Pending & Timeline and Edit History. Lint: ask to create/edit a script and confirm lint runs (headless `--check-only`) and output appears in chat.

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
  - **RAG pipeline** (docs + project_code), **context builder** (budgeted blocks, hard cap at model limit), **editor tools** (file + scene/node edits in Godot), **lint-after-edit** (headless lint + auto-fix up to 5 rounds), and **activity log** in chat (Thinking…, Using tool X, Linting…, Fixing lint…).
  - Editor plugin: streaming answers, apply-immediately flow with timeline and Revert, visual indicators (🟢🟡🔴) in file/scene tree.

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
- Repo indexing (structural graph):
  - `rag_service/app/services/repo_indexing.py` – SQLite-backed file/edge index per project.
  - `rag_service/app/repo_index_<repo_id>.db` – per-project DB (avoids lock contention).
  - `rag_service/scripts/repo-indexer/index_repo.py` – CLI to index a Godot project root.
- Repair memory (lint fixes):
  - `rag_service/app/repair_memory.py` – SQLite store of lint failure → fix (diff + explanation).
  - `rag_service/app/repair_memory.db` – single DB for all projects.

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
    - `top_k: int = 3` (default; fewer RAG chunks to keep context lean).
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
- Backend also defines **editor-action tools** whose handlers return `execute_on_client: true`; the Godot plugin runs those locally (create_file, write_file, apply_patch, create_script, create_node, delete_file, list_directory, list_files, search_files, read_import_options, modify_attribute, lint_file).
- **read_file**: When the plugin sends `context.extra.project_root_abs`, the backend runs it on the server via `read_project_file()` and returns `{ success, path, content, message }` in the tool result so the LLM sees the file content. Essential for “what’s in this file” or editing with correct context. Otherwise returns execute_on_client (plugin runs it; result not fed back to LLM).
- **list_files**, **read_import_options**: When `project_root_abs` is present, backend can run on server and return result to LLM; otherwise execute_on_client.
- **list_files**: List file paths under res:// by optional extension (e.g. all .svg) without searching file contents. Use for “find all SVGs” then e.g. modify_attribute(import) on each.
- **modify_attribute**: Single tool to set an attribute on a target. `target_type='node'` (scene_path, node_path, attribute, value) for node properties; `target_type='import'` (path, attribute, value) for .import [params] keys (e.g. SVG compress, texture mipmaps). Avoids adding a new tool per target kind.
- **read_import_options**: Read the .import file for a resource to see current [params]. Use before modify_attribute(import) to see keys.
- **lint_file**: Editor tool only. The plugin runs Godot headless `--check-only` on the given path and shows the lint output in the chat. The LLM does not receive the lint output in the same conversation turn.

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

## 7. Godot Plugin Dock & UX

- **Chat**:
  - **Enter** sends the message; **Shift+Enter** inserts a newline (gui_input on prompt TextEdit).
  - User message appears instantly; prompt is cleared and the request runs. Response streams in with a typing cursor; the message does not disappear while streaming.
  - **You** vs **Assistant** are visually distinct (blue-tinted right-aligned block for user, green-tinted block for assistant with labels).
  - Default font size is **18** (configurable in Settings). Copy uses `get_parsed_text()` and `DisplayServer.clipboard_set(...)`.
  - **Tools** checkbox: when checked, the dock uses `POST /query_stream_with_tools`; tool calls with `execute_on_client: true` are run by `GodotAIEditorToolExecutor`. Context usage label near chat tabs (e.g. `Ctx: 2% (792/32768)`).
- **Tabs**:
  - **Main tabs** (Chat, Edit History, Settings, Pending & Timeline): `TabContainer.get_tab_bar().drag_to_rearrange_enabled = true`. Tab-change logic uses the **selected child’s node name** (e.g. `Settings`, `History`), not fixed indices, so it still works after the user reorders tabs.
  - **Chat tabs** (Chat 1, Chat 2, …): `TabBar.drag_to_rearrange_enabled = true`; `active_tab_rearranged` is connected so `_chats` is reordered to match the new tab order.
- **Pending & Timeline**: Diff preview (OldText/NewText) shows when a file item is selected; safe node resolution and minimum size so the panel stays visible.
- **Edit History**: Flat ItemList + detail panel (timestamp, summary, files changed, prompt, lint). Data from `GET /edit_events/list?limit=500`; `GET /edit_events/{id}` returns full event with old/new content per file.
- **Plugin load**: If the dock scene fails to load, a fallback panel with an error message is shown; check Output for errors.
- The plugin passes `EditorInterface` into the dock via `set_editor_interface()` so the executor can open scenes, add nodes, and save.

### 7.1 Editor tools: apply immediately + timeline + Revert

- **Apply immediately**: File and node edits from tool calls are **executed right away** (no “pending” accept step). Each file edit is recorded in the local edit store, lint runs per file after apply, and the dock shows status per change.
- **Tool-call contract**: Backend sends `{ "tool_name", "arguments", "output" }`. The dock uses `output` when it has `execute_on_client: true`; otherwise it builds the payload from `tool_name` + `arguments`.
- **File tools** (`editor_tool_executor.gd`): create_file, write_file, apply_patch, create_script, delete_file, read_file, list_directory, search_files, list_files, lint_file (paths under `res://`). **Node/import**: create_node (async), modify_attribute (node or .import [params]). **lint_file**: plugin runs Godot headless `--check-only` and appends lint output to the chat.
- **Local edit store** (`ai_edit_store.gd`): Persisted to `user://godot_ai_assistant_edits.json`. Holds `file_status` (path → status for indicators), `node_status` (scene → node → status), and `events` (timeline, newest first). Used for **editor indicators** and **Revert**.
- **Indicators**: File tree and script tabs show 🟢 created, 🟡 modified, ⚫ deleted, 🔴 failed (lint), by matching paths from `file_status`. Scene tree shows 🧩 created (component) and 🟡 modified for nodes in `node_status` for the open scene. See §7.5 for how decorations are applied and styling constants.
- **Timeline & Revert**: “Pending & Timeline” tab lists all applied changes (file + node) with action-type icons. Selecting a **file** event shows old vs new in the diff panel. **Revert selected** writes `old_content` back to the file and clears that path from `file_status` so the indicator goes away.

### 7.2 Edit history: backend SQLite + plugin local store

- **Backend** (`rag_service/ai_history.db`): `POST /edit_events/create` (plugin posts after tool runs), `GET /edit_events/list`, `POST /edit_events/undo/{id}` (returns tool calls to restore content). The **Edit History** tab in the plugin shows this server-backed list and can trigger undo via the backend.
- **Plugin local store** (`user://godot_ai_assistant_edits.json`): Timeline of applied file/node changes for the **Pending & Timeline** tab, file/node status for 🟢🟡🔴 indicators, and **Revert** (writes `old_content` back without calling the backend). So: server history = list/undo from API; local store = per-session timeline + revert.

### 7.3 Dock layout

- AI dock is in `DOCK_SLOT_RIGHT_UL`; root `custom_minimum_size = Vector2(260, 220)`, `TabContainer` has `clip_contents = true`. Chat output uses word wrap; status label uses ellipsis so it doesn’t force width.

### 7.4 Action types and display

- `ai_edit_store.gd` defines action constants and `get_action_icon()` / `get_action_label()` (e.g. 📄 Add file, ✏️ Write file, 🧩 Create component). Executor returns `edit_record` with `action_type`, `summary`; file and node changes are recorded with `action_type`. Chat appends a formatted “**Editor actions**” section (icon + label + summary). Timeline shows the same icons and summaries.

### 7.5 Editor decorations (styling and discovery)

- **Styling constants** (`ai_edit_store.gd`): All markers are centralized so “staged” state is consistent across script tabs, FileSystem tree, and Scene tree.
  - File: `FILE_MARKER_CREATED` 🟢, `FILE_MARKER_MODIFIED` 🟡, `FILE_MARKER_DELETED` ⚫, `FILE_MARKER_FAILED` 🔴.
  - Node: `NODE_MARKER_CREATED` 🧩 (component just created), `NODE_MARKER_MODIFIED` 🟡.
  - `GodotAIEditStore.strip_markers(s)` strips any of these so decorations can be re-applied without duplicating prefixes.
- **Discovery (no brittle find_child by name)**:
  - **Script tabs**: Use `EditorInterface.get_script_editor()`, then find the TabBar under it; match each tab to `get_open_scripts()[i].resource_path` so markers use the exact script path from `file_status`.
  - **FileSystem tree**: Use `EditorInterface.get_file_system_dock()`, then find the Tree under it. No reliance on a node named `FileSystemDock` in the base control.
  - **Scene tree**: Try `SceneTreeDock` / `Scene` under base; if not found, try `EditorInterface.get_editor_main_screen()` and find `SceneTreeEditor` → Tree. Ensures markers work across different editor layouts/versions.
- **Path matching**: FileSystem tree items may store path in metadata; `_normalize_path_for_match()` normalizes slashes and converts project-absolute paths to `res://` so `file_status` keys (often `res://`) match. Fallback: suffix match on filename when metadata is not a path.
- **When decorations run**: First run is `call_deferred("_apply_editor_decorations")` so FileSystem, Script, and Scene docks exist before searching. A 1s timer refreshes decorations so new tabs/trees get markers.

### 7.6 Chat tabs and settings

- **New chat**: Creating a new chat calls `_ensure_chat_has_messages()` and `_update_context_usage_label()` so the new chat’s state and context label are in sync (no stale context from the previous chat).
- **Settings**: Only the main dock tab “Settings” is used; there is no Settings button on the chat bar. Users change settings via the main Settings tab.

---

## 8. Context builder (efficient prompt assembly)

- Goal: only send what’s necessary; stable ordering; budget-aware trimming.
- Model context limits live in `rag_service/app/context_builder.py` (e.g. `gpt-4.1-mini` uses a conservative `32768`).
- The backend assembles ordered blocks with per-block budgets:
  - System instructions → Current task → Active file → Related files (structural proximity) → Recent edits (recency working set) → Errors → Retrieved knowledge → Optional extras
- Active file handling:
  - The plugin sends `context.current_script` and may send `context.extra.active_file_text`.
  - The plugin always sends `context.extra.project_root_abs` so the backend can read project files directly from disk (playground/local assumption).
  - If `active_file_text` is missing, the backend reads the active file from disk.
- Structural proximity (repo index):
  - When `project_root_abs` is present, the context builder uses the **repo index** (`get_related_res_paths`) to find related files from the SQLite graph (outbound: what this file references/instances; inbound: what references this file), then reads those files and adds them as the “Related files” block. If the project is not yet indexed, it runs a one-off incremental index. See §9.
- Repair memory (lint fixes):
  - When `context.extra.errors_text` or `context.extra.lint_output` is present, the backend looks up past fixes for the same normalized error signature (`search_lint_fixes`) and appends a “Past lint fixes (repair memory)” block to optional extras so the LLM can reuse proven diffs. See §10.
- Recency working set:
  - Backend pulls recent diffs from SQLite and includes them as lightweight context.
- Compression vs truncation:
  - When a block is far over budget, the backend uses a cheap local “compression” fallback (key symbols + head/tail windows) instead of random truncation.
- Debugging:
  - Backend logs the full input payload sent to the LLM with `[llm_input] ...` (printing is made Windows-console-safe).

---

## 9. Repo indexing (SQLite)

- **Purpose**: Fast local graph of “what files exist” and “how they are connected” (scenes → scripts/resources, scripts → `res://` refs, `project.godot` → main/autoload) for structural context without touching Chroma.
- **Storage**: Per-project DB at `rag_service/app/repo_index_<repo_id>.db` (repo_id = hash of project root path) to avoid lock contention when multiple projects or processes are used.
- **Schema**: `repos`, `index_runs`, `files` (path_rel, kind, language, size, mtime, sha256), `edges` (src_rel, dst_res, edge_type: e.g. `attaches_script`, `instances_scene`, `main_scene`, `autoload`, `references_res_path`).
- **Indexing**: `index_repo(project_root_abs, ...)` walks project files (`.godot`, `.tscn`, `.tres`, `.gd`, `.cs`, `.gdshader`), parses `project.godot` and `.tscn` for edges, and optionally scans text for `res://` refs. **Incremental**: only re-parses files whose mtime/size changed; deletes edges for changed sources and removes rows for deleted files.
- **API**: `get_related_res_paths(project_root_abs, active_file_res_path, max_outbound=8, max_inbound=4)` returns a list of `res://` paths (existing files only) for outbound deps and inbound refs, used by the context builder for the “Related files” block.
- **CLI**: From `rag_service/`, `python scripts/repo-indexer/index_repo.py --project-root "C:\path\to\GodotProject"` (script adds `rag_service` to `sys.path` so `app` imports work).

---

## 10. Repair memory (lint fix storage)

- **Purpose**: Store lint failure → successful fix (diff + optional explanation) so the same or similar errors get “past fix” context and the LLM produces more consistent Godot 4.x GDScript.
- **Storage**: Single SQLite DB `rag_service/app/repair_memory.db` with `lint_sessions`, `lint_errors`, `lint_fixes`. Not training the model—improving the **retrieval** layer.
- **Normalization**: Raw lint output is normalized (strip paths, line/column, quoted identifiers) and hashed with `engine_version` to form `error_hash` so repeated identical errors collapse.
- **Endpoints**:
  - `POST /lint_memory/record_fix`: body `project_root_abs`, `file_path`, `engine_version`, `raw_lint_output`, `old_content`, `new_content`, optional `prompt`. Stores session + error + fix (unified diff). If OpenAI is configured, requests a short “explanation” of the fix for the record.
  - `GET /lint_memory/search?engine_version=...&raw_lint_output=...&limit=...`: returns matching past fixes (same `error_hash`) for in-context injection.
- **Plugin**: When auto-lint fix runs and lint later passes, the dock posts the fix (first failure output + before/after content) to `record_fix`. When asking the backend to fix lint, it sends `context.extra.lint_output` so the context builder can attach “Past lint fixes” when available.

---

## 11. Testing & Diagnostics Summary

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

## 12. Implementation notes (for future LLMs)

- **Streaming + tool calls**: `POST /query_stream_with_tools` streams answer text first, then two sentinel blocks: `__TOOL_CALLS__` + JSON array of tool calls, then `__USAGE__` + JSON context_usage. The plugin parses these to run editor tools and update the context label. Tool calls executed on the backend (e.g. read_file when `project_root_abs` is set) are already resolved in that array; only `execute_on_client: true` tools are run in Godot.
- **project_root_abs**: The plugin sends `context.extra.project_root_abs` (absolute path to the project folder containing `project.godot`). The backend uses it to read files on disk (read_file, list_files, read_import_options), to build context (active file, related files via repo index), and for repair memory / edit_events. When opening Godot, open the **project folder** (e.g. `godot_plugin`), not the parent repo root, so paths and plugin discovery work.
- **Plugin tab reorder**: Use `TabBar.drag_to_rearrange_enabled = true` and, for `TabContainer`, `get_tab_bar().drag_to_rearrange_enabled = true`. If the main tab handler relies on indices, switch to the selected **child node name** (e.g. `child.name == "Settings"`) so behavior is correct after the user drag-reorders tabs. For a custom TabBar synced to data (e.g. chat tabs), connect `active_tab_rearranged` and reorder the data array to match the new tab order.
- **Shutdown noise**: Backend uses a custom asyncio exception handler and a logging filter to suppress `CancelledError` tracebacks on Ctrl+C; see `main.py` lifespan and `_SuppressCancelledErrorFilter`.
- **Consistency**: Keep Chroma schema (`docs` / `project_code` metadata), importance tiers, and the plugin’s `/query` request/response contract. Editor tools are apply-immediately with local timeline + Revert; backend edit_events are for list/undo from the History tab.
- **Editor decorations**: Use `EditorInterface.get_file_system_dock()` and `EditorInterface.get_script_editor()` to get the real dock nodes instead of `base.find_child("FileSystemDock", true, false)` (control names can vary by version/locale). Match script tabs to paths via `get_open_scripts()[i].resource_path`. Run the first decoration with `call_deferred("_apply_editor_decorations")` so docks exist before searching for their Tree/TabBar. Normalize paths when matching FileSystem metadata to `file_status` keys (e.g. `res://` form). Use `ProjectSettings.globalize_path("res://")` for project root (Godot 4 has no `ProjectSettings.resource_path`).
- **Godot 4 / GDScript**: `NodePath` has no `trim_prefix`/`path_join`—use `str(node_path).trim_prefix(...)`. Cannot use bare `_` as discard variable; use e.g. `var _x := ...`. If the dock fails to load, use `get_node_or_null()` in `_ready()` for optional nodes so one missing path does not prevent the plugin from loading.

