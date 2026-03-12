## High-level roadmap

- **Goal**: Ship a Godot editor assistant that can:
  - Answer questions about Godot 4.x APIs and patterns.
  - Understand the current project (GDScript, C#, shaders).
  - Call **tools** to inspect, simulate, and safely modify the project.
  - Stay fast, predictable, and easy to reason about.

This file tracks the remaining work, grouped by area. It is intentionally verbose so future work can be delegated to both humans and LLMs.

---

## 1. RAG data & indexing

- **Docs indexing is partially working but still fragile with OpenAI limits.**
  - **Finalize robust doc chunking for embeddings**
    - Ensure `index_docs.py` never sends:
      - Per-record text longer than the OpenAI embedding model allows.
      - A batch whose combined tokens exceed the per-request limit.
    - Remove any emergency truncation that drops content silently; instead:
      - Prefer **hierarchical splitting**: frontmatter → sections (`##`) → subsections (`###`) → fixed windows.
      - Log whenever a document requires fallback splitting and why.
    - Add small test harness:
      - Feed synthetic huge markdown docs through the splitter.
      - Check that all content is preserved (concatenate chunks and diff against original).
      - Assert no chunk length exceeds our hard cap.
  - **Add unit tests around indexing logic**
    - Tests for `infer_engine_version` using different `docs_root` structures.
    - Tests for `_split_markdown_into_chunks` (or equivalent) for:
      - Docs with YAML frontmatter.
      - Docs with only `##` headings.
      - Docs with both `##` and `###` headings.
      - Docs with no headings at all (pure text).
- **Project code indexing (`project_code` collection) needs verification and polish.**
  - Run `analyze_project.py` against a representative set of Godot 4 projects (GDScript-heavy, C#-heavy, shader-heavy).
  - Confirm metadata schema matches what the backend expects:
    - `project_id`, `path`, `language`, `importance`, `tags`.
  - Ensure importance thresholding is doing something sensible (enough samples, but skewed toward important scripts).
  - Add a small “index summary” log after ingest (counts per language, min/median/max importance, etc.).
- **ChromaDB consistency and migrations.**
  - Document and script the **clean reset** procedure clearly:
    - Stop backend.
    - `rm -rf chroma_db/` (or PowerShell equivalent).
    - Re-run `index_docs` and `analyze_project`.
  - Detect and warn on embedding-function mismatches between collections and current `.env` config.
  - Optional: add a tiny “schema version” field in collection metadata to ease future migrations.

---

## 2. Backend API surface (FastAPI / tools)

We want a clear separation between:

- **RAG query API** – what the Godot plugin uses today (`/query`).
- **Tool APIs** – what the LLM can call to do things *other than* plain Q&A.
- **Stabilize `POST /query` contract**
  - Confirm request/response models are fully documented in `CONTEXT.md` and type-annotated in `app/main.py`.
  - Ensure error responses are structured (e.g. `{ "error": { "code": "...", "message": "..." } }`) and non-HTML.
  - Add simple, deterministic smoke tests for `/health` and `/query` without OpenAI (fallback mode).
- **Introduce a tools subsystem in the backend**
  - Create `rag_service/app/tools/__init__.py` and a simple registration mechanism:
    - Each tool has:
      - `name` (e.g. `"list_scenes"`, `"preview_node_tree"`, `"apply_code_patch"`).
      - `description` (natural language, short).
      - `input_schema` and `output_schema` (Pydantic models or JSON Schema-like).
      - `handler` function.
  - Add an internal endpoint `POST /tools/call` that:
    - Accepts `{ tool_name: string, args: object }`.
    - Looks up the registered tool, validates input, executes, and returns structured output.
  - Add `GET /tools/manifest` that returns all tool definitions:
    - For RAG indexing and for the plugin / debugging UIs.
- **Candidate initial tools (backend-side only)**
  - **Search project code** by path / substring / regex (no LLM):
    - Inputs: `query`, optional `language`, optional `max_results`.
    - Output: list of matches with file path, line spans, short previews.
  - **Search docs** via Chroma directly:
    - Inputs: `query`, optional `engine_version`, optional `n_results`.
    - Output: list of `docs` hits with metadata and previews.
  - **Static analysis stubs**:
    - For example, list scripts which extend `CharacterBody2D` and mention `"move_and_slide"` to support common “player controller” queries.

---

## 3. LLM orchestration & tool usage

The LLM should not do everything in one opaque prompt. Instead, it should:

1. Use RAG over docs, project code, and tool reference docs.
2. Decide whether a tool call is needed.
3. Call tools via backend APIs.
4. Summarize results back to the user (and optionally ask Godot to apply an editor action).

- **Design the tool-calling protocol (backend ↔ LLM)**
  - Decide on one approach and implement it:
    - Option A: use OpenAI “tool calls” / function calling to let the model suggest tool invocations.
    - Option B: roll a lightweight custom protocol where the LLM emits a JSON `{"tool": "...", "args": {...}}` block in a reserved channel.
  - Add orchestration code in the backend that:
    - Runs RAG first.
    - Calls the LLM with all context plus a list of available tools (from `/tools/manifest`).
    - Detects tool call requests, executes them, and loops back into the LLM with tool results up to a small, fixed number of steps.
  - Ensure we cap total tokens and number of tool-calling turns.
- **Teach RAG about tools**
  - Generate a **human-readable “Tool Reference” document** (markdown) from the tool manifest:
    - Location: `godot_knowledge_base/docs/tools/tool_reference.md` (or similar).
    - Indexed into the `docs` collection like any other doc.
    - Describes:
      - Tool name, purpose.
      - Inputs / outputs.
      - Caveats (e.g. “editor-only, requires plugin action”).
  - Ensure `/query` includes references to tool capabilities in the system message so the LLM knows tools exist even if retrieval misses the tool doc.
- **Add guardrails around tool usage**
  - Hard limits:
    - Max tools per `/query` request.
    - Max editor-modifying operations per request.
  - Add an internal “dry-run” mode for tools that modify code or scenes, so we can see diffs before applying them.

---

## 4. Godot plugin: current UX and future tools

The editor plugin should remain a **thin, robust client**.

- **Current dock UX polish**
  - Add simple status states (e.g. “Ready”, “Indexing…”, “Calling tools…”) that reflect backend behavior.
  - Make it clear when a response includes **proposed actions** (e.g. “apply patch”, “create script file”) versus just text.
  - Improve error reporting (HTTP errors, backend down, etc.).
- **Define a set of editor actions that the backend can request**
  - Minimal v1 actions:
    - `insert_text_at_cursor` (for quick code suggestions).
    - `replace_selection` in current script.
    - `open_file_at_path_and_line` (navigation only).
  - Slightly more advanced actions (carefully designed):
    - `apply_text_patch` on a file (diff-like structure, not raw text).
    - `create_script_file_from_template` with a validated path.
    - `select_node_in_scene_tree` by path.
  - Plugin should implement these as **small, well-tested GDScript functions** that:
    - Take a JSON payload from the backend.
    - Validate paths / node names.
    - Fail loudly but safely (no crashes) when something is invalid.
- **Wire backend “actions” into the plugin**
  - Extend `/query` responses to optionally include an `actions` array, e.g.:
    - `{ "answer": "...", "snippets": [...], "actions": [ { "type": "apply_text_patch", "path": "...", "diff": "..." } ] }`.
  - Plugin:
    - Renders the answer as usual.
    - Lists any requested actions separately, with user confirmation before executing.
    - Allows re-running a query **without** executing actions for debugging.

---

## 5. Tooling coverage across Godot functionality

This section sketches **future tools** that, together, let the assistant cover most common Godot workflows. Not all of these need to be implemented at once; they form a long-term backlog.

### 5.1 Scene & node graph tools

- **Scene/Node inspector tool**
  - Backend-side:
    - Accepts: `scene_path`, optional `node_path`.
    - Returns: structured representation of nodes, types, attached scripts.
  - Plugin-side:
    - Provides current scene / selected node info to the backend.
  - Use cases:
    - “What script controls this node?”
    - “Why isn’t this signal firing?”
- **Signal wiring analysis tool**
  - Parses the current scene + scripts:
    - Finds `connect` calls, signal definitions, and attached methods.
  - Helps answer:
    - “Is this button connected to anything?”
    - “Where is this signal handled?”

### 5.2 Scripting tools (GDScript, C#)

- **Code search & navigation tools (backend + plugin)**
  - Already partially covered by RAG, but we need:
    - Direct file/line search (regex + symbol-based) to complement embeddings.
- **Refactoring helpers (carefully constrained)**
  - Rename script file + update references (e.g. `extends` paths, `load()` calls).
  - Rename signals or methods across a project (requires static analysis + user confirmation).
- **Lint / best-practice suggestion tool (read-only at first)**
  - Analyze a script and return:
    - Possible performance issues (e.g. heavy work in `_process`).
    - Common Godot anti-patterns.
  - Later, propose **patches** instead of just comments.

### 5.3 Shader tools

- **Shader snippet explainer (already helped by docs/code RAG)**
  - Treat `.gdshader` files as first-class citizens in indexing and retrieval.
- **Shader pattern finder**
  - Tool to search for shaders using particular techniques (noise, distortion, etc.) in the knowledge base.

### 5.4 Project-level tools

- **Project summary tool**
  - Read the indexed `project_code` collection and produce:
    - High-level summary of autoloads, main scenes, player controllers, major systems.
- **Gameplay entrypoint finder**
  - Given a question like “Where is player movement handled?”, call:
    - RAG over `project_code`.
    - Possibly a dedicated project-analysis tool that clusters / ranks candidate scripts.

---

## 6. Testing, diagnostics, and Windows support

- **Unify testing tools across platforms**
  - We now have PowerShell equivalents of:
    - `run_e2e_rag_tests.sh` → `run_e2e_rag_tests.ps1`.
    - `chroma-status.sh` → `chroma-status.ps1`.
  - Document recommended usage for Windows vs. Unix:
    - Windows: PowerShell (`*.ps1`) is primary; bash scripts are optional.
    - Linux/macOS: `*.sh` scripts remain primary.
- **Improve logs and failure messages**
  - Make Chroma-related errors (unable to open DB, embedding errors) point directly to `CONTEXT.md` reset instructions.
  - Ensure all tools log to `tools/testing/logs/` with date-stamped filenames.
- **Automated e2e tests**
  - Add a CI job (even if local-only initially) that:
    - Builds a fresh venv.
    - Runs `index_docs.py` in a trimmed-down docs subset.
    - Runs `analyze_project.py` against a small sample project.
    - Starts backend and runs the e2e RAG tests (possibly in “no OpenAI key” mode).

---

## 7. Documentation for humans and LLMs

- **Developer docs**
  - Extend `README.md` and/or `CONTEXT.md` with:
    - How to run the backend and tools on Windows vs. Unix.
    - How to add a new tool (backend code + tool reference doc).
    - How to reset and inspect ChromaDB.
- **LLM-facing docs**
  - Ensure that for every new capability (tool, collection, metadata field) we:
    - Add a short markdown description under `godot_knowledge_base/docs/`.
    - Re-index docs so the RAG pipeline actually sees those descriptions.
  - Keep `CONTEXT.md` as the **single source of truth** for architecture decisions and ensure it stays in sync with the code.

---

## 8. Future stretch goals

- **Interactive “tool planning” mode**
  - Let the assistant explain which tools it intends to call and in what order before executing them.
- **Per-project configuration**
  - Allow users to define project-specific rules (e.g. preferred node naming conventions, banned APIs) that RAG and tools respect.
- **Safe auto-fix suggestions**
  - Eventually support a workflow where the assistant can propose a batch of changes (code + scenes), show a summary, and let the user accept/apply with one click, with the expectation that everything is reversible via Godot’s version control.

