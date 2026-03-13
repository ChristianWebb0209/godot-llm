## Repair Memory for Lint Errors (Scoped Task)

### Why

The assistant frequently produces **invalid Godot 4.x GDScript** (wrong syntax, wrong engine version assumptions). We already run Godot’s headless `--check-only` linter and auto-fix via backend tool calls, but we **don’t retain** the knowledge of what fixed what. This task adds a local “repair memory” so future lint fixes are faster and more correct.

Important: this is **not training the model**. It’s building a **retrieval-backed memory** of lint failures + the diffs that resolved them, so the LLM can reuse proven transformations.

---

## Goals (MVP)

- **Persist lint failures and their successful fixes** locally in SQLite.
- Store enough data to be reusable:
  - lint output (raw)
  - normalized error type/hash
  - file path, engine version
  - file content before/after (or at least the diff)
  - a short “fix explanation” (LLM-generated if available)
- **Surface past fixes automatically** when lint errors appear again (RAG context builder input).
- Keep it **local-first** (no external infra required).

---

## Non-goals (for MVP)

- No full vector DB / embeddings yet (can add later when there’s enough data).
- No automatic project-wide linting or watcher daemon.
- No attempt to “learn” from non-lint issues (runtime errors, gameplay bugs).

---

## Data Model (SQLite)

Create a separate DB next to the backend for clarity:

- File: `rag_service/app/repair_memory.db`

Tables:

- `lint_sessions`
  - `id` (INTEGER PK)
  - `project_root_abs` (TEXT)
  - `file_path` (TEXT, Godot `res://...` path)
  - `engine_version` (TEXT)
  - `started_ts` / `finished_ts` (REAL)
  - `status` (TEXT: running|ok|error)

- `lint_errors`
  - `id` (INTEGER PK)
  - `session_id` (FK)
  - `error_hash` (TEXT) = sha256(normalized_error + engine_version)
  - `error_type` (TEXT) = coarse category
  - `error_message` (TEXT) = best single-line summary
  - `raw_output` (TEXT) = full lint output
  - `occurred_ts` (REAL)

- `lint_fixes`
  - `id` (INTEGER PK)
  - `session_id` (FK)
  - `error_hash` (TEXT)
  - `old_content` / `new_content` (TEXT)
  - `diff` (TEXT unified diff)
  - `explanation` (TEXT)
  - `model` (TEXT nullable)
  - `created_ts` (REAL)

Indexes:
- `(error_hash, created_ts DESC)`
- `(file_path, created_ts DESC)`

---

## Normalization Rules (MVP)

We must dedupe errors aggressively so we don’t create thousands of near-duplicates.

- Parse lint output into:
  - `error_message`: first non-empty line (fallback to whole output)
  - `error_type`: simple bucketing based on keywords:
    - PARSE_ERROR / TYPE_ERROR / INVALID_CALL / UNKNOWN_IDENTIFIER / OTHER
- Normalize message for hashing:
  - strip absolute paths, `res://` paths, and line/column numbers
  - remove quoted identifiers when present
- Hash:
  - `error_hash = sha256(normalized_message + "|" + engine_version)`

---

## End-to-end Flow

### In the Godot plugin (client)

When auto-lint fix runs (`_lint_and_autofix_return_ok`):

- On each lint failure:
  - capture `lint_output`
  - capture file content **before** fix attempt
  - call backend to propose/apply fixes (already exists)
- When lint becomes OK:
  - capture file content **after**
  - POST a “resolved fix record” to backend with:
    - `engine_version`, `project_root_abs`, `file_path`, `raw_lint_output` (the failing output), `old_content`, `new_content`

### In the backend (server)

- Store a session + error + fix.
- Compute unified diff.
- Generate a short explanation:
  - If OpenAI key configured: ask model to describe fix succinctly.
  - Else: store a deterministic fallback (“diff-based fix recorded”).
- Provide a search function:
  - given `(engine_version, raw_error_output)` return top N recent fixes for the same `error_hash`.

### In the context builder

If the request includes `context.extra.errors_text` or `context.extra.lint_output`, append a block:

“Past lint fixes (repair memory)” with the best-matching fix diffs + explanations.

---

## API

Backend endpoints:

- `POST /lint_memory/record_fix`
  - body:
    - `project_root_abs: str`
    - `file_path: str` (res://...)
    - `engine_version: str`
    - `raw_lint_output: str`
    - `old_content: str`
    - `new_content: str`
    - `prompt: Optional[str]` (what asked the model to fix)
  - response: `{ ok, fix_id, error_hash }`

- `GET /lint_memory/search?engine_version=...&raw_lint_output=...&limit=...`
  - response: `{ ok, results: [...] }`

---

## Success Criteria

- After several auto-fix runs, the backend accumulates a library of fixes.
- When similar lint output occurs again, the model receives a relevant prior fix diff/explanation in-context, improving correctness for Godot 4.x syntax.
