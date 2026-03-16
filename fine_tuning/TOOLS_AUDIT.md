# Tool set audit for first model training

This doc summarizes the current tool set (after removing search_docs, search_project_code, request_component_context) and how it fits training.

## Tool categories

### File & edit (core)
| Tool | Purpose | Training note |
|------|---------|---------------|
| **create_file** | Create empty file; then write_file for content | Use for new files; often paired with write_file. |
| **write_file** | Overwrite full file content | Primary for new script body; .gd has one `extends` at top. |
| **append_to_file** | Append to end of file | Incremental writes. |
| **apply_patch** | Replace old_string with new_string (or unified diff) | Prefer over write_file for small edits. |
| **create_script** | New .gd/.cs with extends + optional template | Use template (character_2d, control, etc.) for boilerplate. |
| **read_file** | Read full file content | Always use before editing; path res://. |
| **delete_file** | Remove file from project | Straightforward. |

### Explore & search (replacement for removed RAG tools)
| Tool | Purpose | Training note |
|------|---------|---------------|
| **list_directory** | List files/folders under res:// | Discover structure. |
| **list_files** | List paths by extension, no content search | Find all .gd, .tscn, .png, etc. |
| **search_files** | Substring search inside files (which files contain text) | Replaces “search project code” for “find where X is used”. |
| **grep_search** | Pattern/regex search with line numbers | Symbol/pattern search; use pattern or query. |
| **project_structure** | Indexed paths under prefix | When project open; project layout. |
| **find_scripts_by_extends** | Scripts extending a class | When project open; e.g. all CharacterBody2D scripts. |
| **find_references_to** | Files referencing a path | When project open; who uses this scene/script. |
| **fetch_url** | HTTP GET a URL | **Use for docs:** official Godot docs, API pages (replaces search_docs). |

### Scene & nodes
| Tool | Purpose | Training note |
|------|---------|---------------|
| **create_node** | Add node to scene | Omit scene_path for current scene; match 2D/3D. |
| **modify_attribute** | Set node or import attribute | node: scene_path, node_path, attribute, value; import: path, attribute, value. |
| **get_node_tree** | Scene tree (names, types, hierarchy) | Current or given .tscn. |
| **get_signals** | Signals for node type or script | Provide node_type and/or script_path. |
| **connect_signal** | Connect signal to callable | scene_path, node_path, signal_name, optional callable_target. |
| **get_export_vars** | @export vars for script/node | script_path or scene_path+node_path. |

### Project & run
| Tool | Purpose | Training note |
|------|---------|---------------|
| **read_import_options** | Read .import file for resource | SVG, textures, etc. |
| **lint_file** | Run Godot linter on script | Before/after edits. |
| **get_project_settings** | project.godot settings | Display, rendering, etc. |
| **get_autoloads** | Autoload list from project.godot | Globals. |
| **get_input_map** | Input action names and keys | For input handling code. |
| **run_terminal_command** | Shell command | Scripts, godot --headless, builds. |
| **run_godot_headless** | Godot headless (scene/script path) | scene_path or script_path required. |
| **run_scene** | Run scene headlessly, capture output | Test loop. |

### Other
| Tool | Purpose | Training note |
|------|---------|---------------|
| **get_recent_changes** | Last N edit events | What was just edited. |
| **search_asset_library** | Godot Asset Library search | Addons/plugins; filter required. |
| **check_errors** | Editor Errors/Warnings panel | Script errors. |

## Fixes applied

- **grep_search**: `pattern` (or `query`) is required; schema and definitions updated.
- **run_godot_headless**: `scene_path` required (script_path is alias); schema and definitions updated.
- **search_asset_library**: `filter` required; schema and definitions updated.
- **get_signals**: Description clarified: “Provide at least one of node_type or script_path.”
- **fetch_url**: Description explicitly says “Use to look up external documentation” so it’s the replacement for search_docs in training.

## Data (train/val/tool_usage.jsonl)

- Remove or rewrite any example that calls **search_docs**, **search_project_code**, or **request_component_context** (filter script already drops those lines).
- For user messages like “Search the documentation for X”, the correct tool is **fetch_url** (with the appropriate Godot docs URL) or an answer without a tool; ensure no remaining examples teach the removed tools.
- After fixing definitions/schema, re-export or hand-edit `schemas/tools.json` so it matches `app.tools.get_registered_tools()` (run `export_tool_schema.py` from repo root with rag_service deps installed).

## Pre-training checklist

1. **Tool schema**: `schemas/tools.json` matches rag_service (run `python fine_tuning/scripts/export_tool_schema.py` from repo root).
2. **No removed tools**: Run `python fine_tuning/scripts/filter_removed_tools.py` to drop search_docs, search_project_code, request_component_context from `data/tool_usage/*.jsonl`.
3. **Validate**: Run `python fine_tuning/scripts/validate_tool_examples.py` — must pass (all tool_calls reference tools in schema).
4. **Data path**: Colab reads `fine_tuning/data/tool_usage/train.jsonl` and `val.jsonl`. If you use `prepare_tool_dataset.py`, it now writes there (no manual copy).
5. **grep_search**: Schema requires `pattern`; the backend also accepts `query` as an alias. Training examples should include `pattern` (or both).
6. **get_signals**: At least one of `node_type` or `script_path` should be provided; examples in data do provide one.
