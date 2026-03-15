## Godot LLM Assistant

This repo is an experiment in “AI‑native” Godot development. It has **three** main parts that work together, but you can use each one on its own:

- `fine_tuning/` – experimental fine‑tuning pipeline for a **custom coding model for Godot**, with tool‑use baked in.
- `godot_plugin/` – the **Godot editor plugin** that adds an AI assistant dock inside the editor.
- `rag_service/` – a **Python RAG + tools backend** that understands Godot docs, example projects, and your open project, and exposes a tool API to the plugin (and to future models).

The repo assumes Windows/PowerShell for the helper scripts (`.ps1`), but the Python and Godot code are cross‑platform.

---

## 1. High‑level architecture

- **Goal**: make it feel like Godot ships with a built‑in AI assistant that:
  - Knows **Godot 4.x** APIs and patterns.
  - Can **read and edit your project** (files, scenes, nodes) using tools, not just wall‑of‑text suggestions.
  - Optionally runs on a **fine‑tuned coding model** that already “speaks Godot” and understands the same tools as the backend.

At a high level:

- The **Godot plugin** collects editor context (current script/scene, engine version, pinned files/nodes, lint output, etc.) and sends a `/query` to the backend.
- The **RAG service**:
  - Pulls in relevant docs + example code from a local ChromaDB.
  - Builds a **budgeted context** around your project (active file, related files, scene graph, recent edits, lint, etc.).
  - Calls an LLM with a **tool schema** (file/scene/node/edit tools, search tools, lint, repo index, etc.).
  - Streams back:
    - The assistant’s answer text.
    - A set of **tool calls** to apply in the editor (create files, patch scripts, create nodes, etc.).
- The plugin then **runs those tool calls inside Godot** and shows a timeline + edit history, with lint‑aware follow‑up fixes.
- The **fine‑tuning pipeline** is how we eventually replace the generic LLM with a **specialized coding model for Godot** that already understands these tools and conventions.

If you want deeper backend details, see `rag_service/RAG_CONTEXT.md`. This README just explains what lives where and what it’s for.

---

## 2. The three parts of the repo

### 2.1 `fine_tuning/` – experimental Godot coding model

This folder is about training a **small‑to‑medium coding model** that’s tuned specifically for Godot and for this tool set.

- **What it is**
  - Scripts + a Colab‑friendly training script to:
    - Export the backend **tool schema** (`scripts/export_tool_schema.py`).
    - Prepare tool‑use and code‑style datasets (`fine_tuning/data/**`).
    - Fine‑tune a base model (e.g. Gemma‑style / QLoRA) in Colab (`colab/train_lora_gemma_tools.py`).
  - The fine‑tuned model is expected to **emit the same tool names and argument shapes** as `rag_service/app/services/tools.py`.

- **You don’t need this to use the plugin.** It’s here so we can eventually swap in a Godot‑aware model without changing the rest of the stack.

---

### 2.2 `godot_plugin/` – AI assistant dock for Godot

This is a **Godot 4 editor plugin** that adds an “AI Assistant” dock on the right side of the editor.

- **Location**
  - `godot_plugin/addons/godot_ai_assistant/`.

- **What it does**
  - Adds a dock with:
    - **Chat** tab – multi‑chat UI, streaming answers, markdown rendering, a small activity indicator (“Thinking…”, “Calling AI…”, etc.).
    - **Edit History** tab – uses `rag_service`’s edit‑history API to show past edits and let you undo via the backend.
    - **Pending & Timeline** tab – shows file/node changes the assistant has applied, with diff viewer and “Revert selected”.
    - **Settings** tab – backend URL, model choice, text size/word wrap, context‑usage viewer and indexing status.
  - Sends rich editor context to the backend:
    - Current script and scene, selection hints, pinned files/nodes, conversation history, and lint output.
  - Applies tool calls from the backend directly to your project:
    - File operations (create/write/patch/delete).
    - Scene/node operations (create nodes, attach scripts, tweak properties).
    - Lint + autofix (run lint, then request follow‑up fixes until clean or a small cap).
  - Tracks changes for:
    - Editor decorations (markers in FileSystem, Script, and Scene trees).
    - Local per‑session timeline and Revert, even without calling the backend.

- **Install into a project (Windows junction example)**

```powershell
cd C:\Games\MyGodotProject
mkdir addons

mklink /J `
  "addons\godot_ai_assistant" `
  "C:\Github\godot-llm\godot_plugin\addons\godot_ai_assistant"
```

Then in Godot:

1. `Project → Project Settings → Plugins` → enable **Godot AI Assistant**.
2. Point the plugin at your backend URL (default `http://127.0.0.1:8000`).
3. Open the **AI Assistant** dock and start chatting.

---

### 2.3 `rag_service/` – RAG backend + tools for Godot

The `rag_service` folder is a **FastAPI** backend plus helper scripts for scraping docs, analyzing projects, and indexing into ChromaDB and SQLite.

- **What it does**
  - Serves:
    - `GET /health` – simple health check.
    - `POST /query`, `/query_stream`, `/query_stream_with_tools` – main RAG + tools endpoints used by the plugin.
    - Lint endpoints and edit‑history endpoints used by the plugin’s History and lint flows.
  - Uses **ChromaDB** at `rag_service/data/chroma_db/` for:
    - A `docs` collection (scraped Godot docs).
    - A `project_code` collection (curated example projects).
  - Uses SQLite DBs under `rag_service/data/db/` for:
    - `ai_history.db` – edit history and LLM usage.
    - `repair_memory.db` – lint “repair memory” (stores normalized lint errors + successful fixes so we can suggest better fixes next time).
    - `repo_index*.db` – per‑project structural repo indexes (files, edges, references).
  - Builds a **context window** around your active file and scene (plus past edits, lint, etc.) and feeds that to the LLM along with the tool schema.
  - Executes some tools server‑side (file reads/search/index queries) so the model sees **real results** in a single round trip.

- **Important note about training/indexing data**
  - Some of the underlying **training/index data** (for example, certain scraped projects or docs in `godot_knowledge_base/`) is **not included in this repo** and will remain private because the original sources did not explicitly consent to redistribution.
  - The code here is designed so you can plug in your own corpora and re‑index Chroma/SQLite locally.

- **Very short “run it” guide (Windows/PowerShell)**

```powershell
cd C:\Github\godot-llm\rag_service

py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r .\requirements.txt

.\run_backend.ps1
# Check: http://127.0.0.1:8000/health
```

Once the backend is up, point the Godot plugin at `http://127.0.0.1:8000` in the Settings tab and you’re set.

---

## 3. What’s actively being worked on

- **Backend (`rag_service`)**
  - Keeping all runtime data in `rag_service/data/` (Chroma + all SQLite DBs).
  - Improving context assembly around the current script/scene and repo index.
  - Making tool usage more robust, especially around lint + repair memory and structural queries.

- **Godot plugin**
  - Polishing the UI (chat tabs, context viewer, timeline).
  - Stronger editor integration: better decorations, clearer status, safer undo/revert flows.

- **Fine‑tuning (`fine_tuning`)**
  - Generating higher‑quality tool‑use datasets that match the current `tools.py` schema.
  - Running QLoRA experiments for a Godot‑aware coding model.
  - Eventually wiring a fine‑tuned model into `rag_service` as an alternative to the default LLM backend.

---

## 4. Quick start summary

- To **try the assistant in Godot**:
  - Run the backend from `rag_service/`.
  - Link `godot_plugin/addons/godot_ai_assistant` into your Godot project’s `addons/`.
  - Enable the plugin and set the backend URL.

- To **hack on the model side**:
  - Read `fine_tuning/fine-tuning-plan.md`.
  - Explore `fine_tuning/colab/train_lora_gemma_tools.py` and the scripts under `fine_tuning/scripts/`.

The three pieces are intentionally decoupled, so you can evolve the backend, the plugin, and the model at different speeds.

