# OpenViking in `rag_service`

## What it does

OpenViking provides **per-chat “session memory”**:

- **Before** the LLM runs, the backend does a semantic memory lookup for the current question and injects the results into the prompt as the context block **“Retrieved session memory”**.
- **After** the LLM produces an answer, the backend appends the `(user question, assistant answer)` turn to the chat’s OpenViking session and **commits** so OpenViking can extract/update memories.

This is **best-effort**: if OpenViking is missing/disabled or any call fails, the feature silently no-ops.

## Where it’s wired

- **Integration wrapper**: `rag_service/app/services/context/openviking_context.py`
  - `_is_enabled()` gates on installed package + `OPENVIKING_ENABLED`.
  - Stores one OpenViking client per chat_id (cached) and uses a per-chat directory.
  - `find_memories(chat_id, query, top_k)` → list of `{uri, abstract, overview?, content?}`.
  - `add_turn_and_commit(chat_id, messages)` adds messages then `session.commit()`.
  - `ensure_openviking_data_dir()` creates the base folders during app startup.
- **Request path**: `rag_service/app/main.py`
  - Startup (`lifespan`): calls `ensure_openviking_data_dir()`.
  - Query (`_run_query_with_tools`):
    - If `chat_id` is present, calls `openviking_find_memories(chat_id, question, top_k=5)`.
    - For each result, picks the first non-empty of `overview`, `content`, `abstract`, and passes those strings as `retrieved_memories` into the context builder.
    - After an answer is produced, calls `openviking_add_turn_and_commit(chat_id, [{"role":"user",...},{"role":"assistant",...}])`.
- **Prompt injection point**: `rag_service/app/services/context/context_builder.py`
  - `build_ordered_blocks(... retrieved_memories=...)` creates the **“Retrieved session memory”** block (priority `PRIORITY_SESSION_MEMORY`) and budgets it separately (`session_memory_budget`).

## Configuration

Environment variables (read in `openviking_context.py`):

- **`OPENVIKING_ENABLED`**: `1|true|yes` enables; anything else disables.
- **`OPENVIKING_PATH`** (optional): overrides storage root.

Storage default:

- If `OPENVIKING_PATH` is not set, base dir is `rag_service/data/openviking/`.
- Per chat: `rag_service/data/openviking/sessions/<sanitized_chat_id>/`.

Dependency:

- `rag_service/requirements.txt` includes `openviking>=0.1.14`.

## Inputs required for it to work

The request must include a stable `chat_id` (sent by the Godot plugin in `context.extra.chat_id`), otherwise memory retrieval/commit is skipped.

