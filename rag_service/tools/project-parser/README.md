## Godot Project Parser & Ranker

This tool family is responsible for taking **many Godot demo/projects**, parsing
their structure, and turning them into **RAG‑friendly metadata**:

- What scripts and scenes exist?
- How “important” is each script/scene within the project?
- What tags/roles best describe each file?
- How should we surface these to the retriever (project manifests)?

The goal is to let us ingest **multiple GB of Godot projects** while still
giving the RAG system a **high‑signal view** of each project: it should find
the right examples quickly instead of wading through every file equally.

---

## High‑level pipeline

For each Godot project (demo) we import:

1. **Normalize location / inputs**
   - We support **two input modes**:
     - **Local projects** (e.g. output from Godot RE or manually downloaded repos)
       - Example locations outside this repo:
         - `D:\godot-projects\reversed\some_game\`
         - `D:\godot-projects\demos\official\platformer_2d\`
       - The parser will read from these paths and write structured output into:
         - `godot_knowledge_base/code/demos/<slug>/`
     - **Web‑scraped projects** (future)
       - A separate scraper can download Godot projects (zip/tar) to a temp dir.
       - The parser still only sees them as local folders.

2. **Parse Godot metadata**
   - Read `project.godot`:
     - `run/main_scene` – the entry point.
     - `autoload` – singletons (globals).
   - Parse `.tscn` scenes:
     - Which scripts are attached to which nodes.
     - Root node type (`CharacterBody2D`, `Control`, `Node3D`, etc.).

3. **Build a project graph**
   - Nodes: scenes, scripts, autoloads.
   - Edges:
     - Scene → script (attached script).
     - Scene → child scene (instanced via `PackedScene`/`ExtResource`).
     - Autoload → script file.
   - From this we can compute which scripts/scenes are on the **main path**
     from the entry scene, and which are leaf utilities or unused.

4. **Compute an importance score per script/scene**
   - Use structural + heuristic signals (see below).

5. **Auto‑tag each script/scene**
   - Based on base class, path names, and API usage.

6. **Emit project‑level manifest + per‑file metadata**
   - `PROJECT.md` with a summary and a list of key components.
   - A machine‑readable JSON (or similar) for the indexer.

The RAG indexer then uses this metadata to:

- Prefer high‑importance files at retrieval time.
- Quickly find “player controller”, “pause menu”, “enemy AI” patterns across many projects.

---

## Importance scoring (how we rank scripts/scenes)

Each script/scene gets an **importance** score in \[0, 1\]. Inputs include:

### 1. Graph centrality / reachability

- **Main‑graph membership**:
  - +1 if the script is:
    - Attached in the `run/main_scene` or any scene reachable from it.
    - Or an `autoload` script (global).
- **Number of references**:
  - Upweight scripts attached to many scenes or referenced from multiple places.

### 2. Role from base class / root node

- Parse the GDScript `extends` line:
  - `extends CharacterBody2D` → likely a **2D character controller**.
  - `extends CharacterBody3D` → **3D character controller**.
  - `extends Control` → **UI** (menus, HUD, etc.).
  - `extends Node2D` / `Node3D` / `Node` → general logic, up to context.
- For scenes, use the **root node type**:
  - `Node2D` + `Camera2D` + `CharacterBody2D` child → gameplay scene.
  - `Control` + `Button`/`Label` children → menu or HUD.

These signals help us identify “core gameplay scripts” vs background helpers.

### 3. Path and naming heuristics

- File/folder names:
  - `player/Player.gd`, `*Player*` → `["player"]`.
  - `enemy`, `mob`, `ai` in path → `["enemy", "ai"]`.
  - `ui`, `menu`, `hud`, `pause` → `["ui", "menu"]`.
  - `level`, `world`, `map` → `["level"]`.

Names heavily influence both **tags** and **importance** (e.g. player/enemy
scripts are generally more important than a random helper).

### 4. Size / complexity bounds

- We prefer scripts in a **reasonable LOC range** (roughly 10–300 lines):
  - Very small scripts (1–5 lines) often trivial.
  - Very large scripts (800+ lines) are noisy and harder to use as exemplars.
- We downweight extremely large or extremely small scripts unless other
  signals say they are central (e.g. a big `Game.gd` that is clearly core).

### 5. Godot API “richness”

Upweight scripts that exercise **core Godot concepts** the LLM should learn:

- Signals:
  - Declares/uses `signal`, `.connect(`, `emit_signal`.
- Input handling:
  - Uses `Input.is_action_pressed`, `InputMap`, etc.
- Exported properties:
  - Uses `@export` or `export` to integrate with the editor.
- Engine callbacks:
  - `_ready`, `_process`, `_physics_process`, `_input`, etc.
- Physics:
  - Calls `move_and_slide`, `move_and_collide`, uses physics bodies.

These scripts are ideal for teaching **idiomatic Godot usage**,
so they get higher importance.

### 6. Combined scoring

Rough sketch (actual weights TBD in code):

```text
importance =
  0.4 * main_graph_score
+ 0.2 * centrality_score
+ 0.2 * godot_api_score
+ 0.1 * name_path_score
+ 0.1 * size_score
```

Then normalize into \[0, 1\] per project.

---

## Tagging and roles

Tags are short, reusable labels we attach to each script/scene, derived from:

- **Base class / root node**:
  - `CharacterBody2D` → `["2d", "movement", "character"]`
  - `CharacterBody3D` → `["3d", "movement", "character"]`
  - `Control` → `["ui"]`
  - `Node2D` / `Node3D` → `["2d"]` / `["3d"]`
- **Path keywords**:
  - `player`, `hero` → `["player"]`
  - `enemy`, `mob` → `["enemy", "ai"]`
  - `menu`, `hud`, `pause` → `["ui", "menu"]`
- **API usage**:
  - Input APIs → `["input"]`
  - Signals → `["signals"]`
  - Physics movement → `["physics", "movement"]`

We may also infer a **role** string from tags + path + base class, for example:

- `["2d", "movement", "character", "player"]` + `CharacterBody2D`
  → `role: "2d_player_controller"`
- `["ui", "menu", "pause"]` + `Control`
  → `role: "pause_menu_ui"`

These roles get written into the project manifest and into per‑chunk metadata
so the retriever can prioritize the right pieces.

---

## Project manifests (`PROJECT.md`)

For each imported project under `code/demos/<slug>/`, we emit:

- `godot_knowledge_base/code/demos/<slug>/PROJECT.md`

Example structure:

```markdown
---
project_id: topdown_shooter
engine_version: 4.2
tags: ["2d", "shooter", "demo"]
components:
  - path: res://player/Player.gd
    role: 2d_player_controller
    tags: ["2d", "movement", "CharacterBody2D", "player"]
    importance: 0.95
  - path: res://ui/PauseMenu.tscn
    role: pause_menu_ui
    tags: ["ui", "pause_menu"]
    importance: 0.8
  - path: res://enemies/Enemy.gd
    role: basic_enemy_ai
    tags: ["enemy", "ai", "2d"]
    importance: 0.88
  # ...
---

Short natural‑language summary of the project and its main systems...
```

In addition, we keep a machine‑readable metadata file (e.g. JSON) that lists
each script/scene with:

- `file_path`
- `base_class` or `root_node`
- `tags`
- `role` (if inferred)
- `importance`

The RAG indexer can then:

- Embed both manifests and individual code chunks.
- Use `importance` to bias retrieval toward the best examples.
- Use `tags`/`role` to filter by intent (e.g. “enemy AI”, “pause menu”).

---

## Scanning the scene graph and structure

The parser will roughly:

1. **Parse `project.godot`**
   - Extract:
     - `run/main_scene`
     - `autoload` entries (names → script paths).

2. **Parse all `.tscn` scenes**
   - Use a simple TSCN parser (it’s a text INI‑like format) to find:
     - Root `[node]` section: type (e.g. `Node2D`, `Control`, `Node3D`).
     - `script = ExtResource("res://...")` lines to link nodes to scripts.
     - Instanced sub‑scenes (`[node instance=ExtResource(...)]`).

3. **Build a graph**
   - Start from `main_scene`:
     - BFS/DFS over instanced scenes.
     - Record which scenes/scripts are reachable.
   - Add autoload scripts as always‑reachable.

4. **Collect script info**
   - For each `*.gd`:
     - Parse the header to find `extends`.
     - Compute:
       - Line count (LOC).
       - Simple metrics (contains `signal`, `_ready`, `move_and_slide`, etc.).
       - Path‑based tags.

5. **Compute metrics + importance**
   - Combine:
     - Reachability / centrality.
     - Base class / node role.
     - Name/path hints.
     - Size & API usage.

6. **Write manifests + metadata**
   - `PROJECT.md` for humans and LLM context.
   - JSON (or similar) for the retriever/indexer.

---

## How this feeds RAG

At retrieval time, the RAG layer will:

- Have separate indexes for:
  - Official docs.
  - Snippets/patterns.
  - Project code (with metadata from this parser).
- When it needs project examples:
  - First hit `PROJECT.md` manifests to find relevant projects/components.
  - Then retrieve code chunks from scripts/scenes with:
    - Matching tags/roles.
    - Higher `importance`.

This lets us safely ingest **many GB of demos** while still surfacing the
right examples quickly, and it preserves enough structure to build
higher‑level reasoning on top (“show me a good pause menu example in a 2D
project”, “show me how to structure a character controller in Godot 4”, etc.).

---

## Usage scenarios (how you’ll actually run this)

### 1. Local reversed‑engineered / downloaded projects

You’ll have projects on disk from Godot RE or manual downloads, e.g.:

- `D:\godot-projects\reversed\game_a\`
- `D:\godot-projects\reversed\game_b\`
- `D:\godot-projects\demos\official\platformer_2d\`

The parser script (to be implemented here) will:

- Take one or more **source project roots** (outside this repo).
- For each root:
  - Parse `project.godot`, `.tscn`, `.gd`.
  - Ignore large binary/asset files (`.png`, `.ogg`, `.mp4`, `.import`, etc.).
  - Compute importance/tags/roles as described above.
  - Write:
    - `godot_knowledge_base/code/demos/<slug>/PROJECT.md`
    - `godot_knowledge_base/code/demos/<slug>/meta.json` (or similar)
    - Optionally, a text‑only mirror of scripts + scenes for indexing.

You can rerun this script whenever you add new reversed projects.

### 2. Web‑scraped project archives

If you build a future web scraper for Godot projects:

- That scraper:
  - Downloads `.zip` / `.tar` archives to a temp dir.
  - Extracts them to a local folder.
- The **project parser**:
  - Doesn’t care where the project came from.
  - Is called with `--source-root` pointing at the extracted project.

This keeps responsibilities clean:

- Web scraping layer = just download/extract.
- Project parser layer = understand Godot structure and produce RAG metadata.

---

## Implementation guide (planned CLI & behavior)

> This section describes how we’ll implement the parser scripts.

### CLI shape (proposal)

We’ll create a CLI tool, e.g. `rag_service/tools/project-parser/analyze_project.py` with a CLI like:

```bash
python analyze_project.py \
  --source-root "D:\godot-projects\reversed\game_a" \
  --output-root "..\..\..\godot_knowledge_base\code\demos\game_a"
```

Key flags:

- `--source-root`: path to a **Godot project root** (contains `project.godot`).
- `--output-root`: where to place:
  - `PROJECT.md`
  - `meta.json` (per‑file metadata)
  - (optional) a pruned text‑only copy of the project for indexing only.
- `--slug` (optional): override the project_id/slug if needed.
- `--dry-run` (optional): print summary/stats without writing files.

We can also add a **batch mode**:

```bash
python analyze_project.py \
  --projects-root "D:\godot-projects\reversed" \
  --output-root "..\..\..\godot_knowledge_base\code\demos"
```

Where the script:

- Walks subdirectories under `projects-root`.
- Treats each folder containing a `project.godot` as a project.

### File/asset filtering

The parser will:

- **Only parse**:
  - `project.godot`
  - `*.tscn` (scenes)
  - `*.gd` (GDScript)
  - `*.tres` if it’s small and text‑based and relevant.
- **Ignore or skip**:
  - Images: `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.svg`
  - Audio: `.wav`, `.ogg`, `.mp3`
  - Videos: `.mp4`, `.webm`
  - Import metadata: `*.import`
  - Binaries: `.pck`, `.exe`, etc.

This keeps the knowledge base light and focused on **code + scenes**.

### Core parsing steps (summary)

1. **Verify project**
   - Check `project.godot` exists under `--source-root`.

2. **Read project.godot**
   - Extract:
     - `run/main_scene`
     - `autoload` scripts.

3. **Walk `.tscn` files**
   - For each scene:
     - Record:
       - Path.
       - Root node type.
       - Attached scripts.
       - Instanced sub‑scenes.

4. **Walk `.gd` files**
   - For each script:
     - Read:
       - `extends` (base class).
       - Line count.
       - Simple regex‑based feature flags:
         - Uses `signal`, `.connect`, `emit_signal`.
         - Uses `Input.is_action_*`, `InputMap`.
         - Uses `_ready`, `_process`, `_physics_process`, `_input`.
         - Uses `move_and_slide`, `move_and_collide`.

5. **Build scene/script graph**
   - Nodes: scenes, scripts, autoloads.
   - Edges:
     - Scene → script.
     - Scene → sub‑scene.
     - Autoload → script.
   - Starting from `main_scene`, mark everything reachable.

6. **Compute importance + tags + roles**
   - Apply the scoring and tagging rules described earlier.

7. **Write output**
   - `PROJECT.md` (human + LLM facing).
   - `meta.json` (machine‑readable summary).
   - (optional) copy `.gd`/`.tscn` into the `output-root` for indexing only.

---

## Future extension: mixed local + remote sources

Once this parser is solid, we can:

- Use it directly on:
  - Local reversed projects (Godot RE output).
  - Downloaded zips from GitHub or itch.io.
- Integrate it into a **higher‑level ingestion pipeline** that:
  - Scrapes a curated list of Godot 4.x repos.
  - Extracts them to a staging area.
  - Calls `analyze_project.py` on each.
  - Updates `godot_knowledge_base/code/**` and related metadata.

The RAG layer doesn’t need to know whether a project came from RE or GitHub;
it just consumes the **normalized manifests and per‑file metadata** produced
by this tool.

