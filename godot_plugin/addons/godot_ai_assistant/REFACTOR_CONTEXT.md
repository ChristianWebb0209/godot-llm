## Godot AI Assistant – Refactor Context (MVC + ai_dock split)

This document captures **what has been done so far in the refactor** and **how to safely complete the remaining work**, especially driving `ai_dock.gd` under 1000 lines while keeping strict MVC-ish separation.

If you are a new contributor or agent, read this once before touching the plugin.

---

## 1. High‑level goals

- **Speed up iteration** on the Godot AI Assistant plugin by:
  - Removing the `ai_dock.gd` “god object”.
  - Isolating UI, state, side effects, and editor integration into clear layers.
  - Sharing a **single UI scene** between the dock and the main “Agent Manager” page.
- **Enforce an MVC‑like structure**:
  - **Models / Stores**: hold data + pure state transitions; no UI or editor dependencies.
  - **Views**: Godot scenes and small scripts that only do node wiring and signal emission.
  - **Controllers / Services**: side effects and orchestration (HTTP, tools, lint, editor actions).
- **Hard technical constraint**:
  - No `.gd` file in the plugin should exceed **1000 lines**.

---

## 2. Current architecture (after refactor)

### 2.1 Entry plugin and surfaces

- `godot_ai_assistant.gd` (`@tool`, extends `EditorPlugin`)
  - Creates a single `GodotAIAgentStore` on `_enter_tree()`.
  - Preloads `ui/ai_surface.tscn` once and instantiates it **twice**:
    - **Dock surface**: added to `DOCK_SLOT_RIGHT_UL`.
    - **Main screen surface**: added to the editor main panel.
  - Sets `GodotAISurface.layout_variant` to either `DOCK` or `MAIN_SCREEN`.
  - Injects the shared `GodotAIAgentStore` into each surface.
  - Registers editor context‑menu plugins for “Add to context”.

- `ui/ai_surface.tscn` + `ui/ai_surface.gd` (`GodotAISurface`)
  - Single shared UI scene for both dock and main screen.
  - Contains a `TabContainer` with:
    - `Chat` tab
    - `Changes` tab
    - `Settings` tab
  - `ai_surface.gd` is intentionally tiny:
    - Applies layout differences for `DOCK` vs `MAIN_SCREEN` (anchors, size flags).
    - All other behavior is inherited from `GodotAIDock` and helpers.

### 2.2 MVC boundaries (enforced by folder layout)

- **Models / Stores** (UI‑agnostic):
  - `core/agent_store.gd` – `GodotAIAgentStore`
    - Single source of truth for chats: `[{ id, title, messages, context_usage, ... }]`.
    - Shared by both surfaces via the plugin entry.
  - `core/stores/chat_session_store.gd` – `GodotAIChatSessionStore`
    - Per‑session UI state (activity, scroll flags).
  - `ai_edit_store.gd` – `GodotAIEditStore`
    - Tracks pending edits, history, revert info.
  - `settings.gd` – `GodotAISettings`
    - Stores display/backend settings, RAG URL, model, etc.

- **Views** (scenes and view scripts):
  - `ui/ai_surface.tscn`, `ui/ai_surface.gd`
  - `ui/components/chat_input_bar.tscn` / `chat_input_bar.gd`
  - `ui/components/chat_message_block.tscn` / `chat_message_block.gd`
  - `ui_tabs/changes_tab.gd`, `ui_tabs/history_tab.gd`, `ui_tabs/settings_tab.gd`
  - `ui_tabs/context_menu_add_to_context.gd`

- **Controllers / Services**:
  - `dock/*`: controllers that are logically attached to the dock view
    - `dock/chat_streaming.gd` – chat send + streaming pipeline.
    - `dock/chat_ux.gd` – scroll‑follow, ask button state, typewriter reveal, ask‑panel animation, prompt/focus/ESC behavior.
    - `dock/pinned_context.gd` – pinned context handling and serialization.
    - `dock/context_viewer.gd` – context viewer toggle + rendering.
    - `dock/chat_context_menu.gd` – chat right‑click menu (copy / export).
    - `dock/http_request_handler.gd` – HTTPRequest lifecycle (health + non‑streaming responses).
    - `dock/tool_follow_up.gd` – tool execution follow‑ups (lint fix loop).
    - `dock/editor_chrome.gd` – TabBar theming and decoration refresh timer.
  - `chat/*`: controllers/helpers focused on chat data/representation
    - `chat/chat_state.gd` – chat tab management, default chat, prompt drafts per tab.
    - `chat/chat_renderer.gd` – incremental rendering into `chat_message_block` components.
    - `chat/markdown_renderer.gd` – Markdown → BBCode for RichTextLabel.
    - `chat/activity_state.gd` – activity state and UI updates.
    - `chat/prompt_input.gd` – drag‑and‑drop into prompt for context; forwards to pinned_context.
    - `chat/chat_drop_zone.gd` – additional drag‑and‑drop handling.
    - `chat/ask_resolver.gd` – parse “ask”/options flows.
  - `backend/*`:
    - `backend/backend_api.gd` – backend HTTP endpoints (query, tools, etc.).
    - `backend/tool_runner.gd` – orchestrates backend `tool_calls` → editor tool executor payloads.
  - `tools/*` – editor tool implementations (filesystem, node ops, run, previews, lint, etc.).
  - `editor/*`:
    - `editor/editor_decorator.gd` – apply file/node decorations based on `ai_edit_store`.
    - `editor/diff_review.gd`, `editor/diff_calculator.gd`, `editor/follow_editor.gd` – diff and follow‑behavior helpers.
  - `services/*`:
    - `services/lint_service.gd` – backend lint wrapper that `ai_dock.gd` can call.

---

## 3. What has been done to `ai_dock.gd`

`ai_dock.gd` is still the **composition root** for the dock surface, but many responsibilities have been pushed out to helpers. Major extractions:

1. **Chat streaming pipeline**  
   - Old: `_on_ask_button_pressed()`, `_deferred_send_question()`, `_async_stream_request()`, `_on_stream_chunk()`, `_on_stream_done()` lived in `ai_dock.gd`.  
   - New: all of this has been moved to `dock/chat_streaming.gd` (`GodotAIChatStreaming`).
   - `ai_dock.gd` now:
     - Owns an instance `_chat_streaming`.
     - Delegates the send/stream workflow to that helper.

2. **Pinned context**  
   - Old: `_pinned_context_contains`, `add_pinned_context_from_drag_data`, `get_current_chat_pinned_context`, `remove_pinned_context`, `_build_pinned_context_extra`, `_refresh_pinned_context_row`.  
   - New: all moved into `dock/pinned_context.gd` (`GodotAIPinnedContext`), with `ai_dock.gd` exposing small wrappers that delegate to `_pinned_context`.

3. **Context viewer**  
   - Old: `_on_context_viewer_button_pressed`, `_refresh_context_viewer_panel`, `_toggle_exclude_context_block`.  
   - New: moved into `dock/context_viewer.gd` (`GodotAIContextViewer`).

4. **Chat context menu (copy/export)**  
   - Old: `_on_chat_gui_input`, `_on_chat_context_menu_id_pressed`, `_copy_message_at_index`, `_copy_whole_chat`, `_on_export_chat_file_selected`.  
   - New: moved into `dock/chat_context_menu.gd` (`GodotAIChatContextMenu`).

5. **HTTP request completion + health check**  
   - Old: `_on_http_request_completed` and `_start_health_check` lived in `ai_dock.gd`.  
   - New: `dock/http_request_handler.gd` (`GodotAIHttpRequestHandler`) owns:
     - `start_health_check()`
     - `on_http_request_completed(...)`
   - `ai_dock.gd` exposes a few tiny helpers (`set_status`, `append_error_to_chat`, `get/set/clear_pending_http_kind`, `handle_backend_health_response()`, `handle_backend_query_response()`) used by the handler.

6. **Tool execution + lint follow‑up glue**  
   - Old: `_run_editor_actions_then_lint_follow_up` and `send_lint_fix_follow_up` lived in `ai_dock.gd`.  
   - New:
     - `backend/tool_runner.gd` focuses on `tool_calls` → executor payload and execution.
     - `dock/tool_follow_up.gd` (`GodotAIToolFollowUp`) owns:
       - Running tool calls and then lint follow‑ups.
       - Managing the bounded “lint fix follow‑up loop” (using `LINT_FOLLOW_UP_CAP`).

7. **Editor “chrome” / decorations timer**  
   - Old: `_apply_chat_tab_bar_editor_style`, `_start_decoration_refresh`, `_on_decoration_timer_timeout`, `_reschedule_decoration_timer` lived in `ai_dock.gd`.  
   - New: moved into `dock/editor_chrome.gd` (`GodotAIEditorChrome`), with `ai_dock.gd` only:
     - Instantiating `_editor_chrome`.
     - Calling `apply_chat_tab_bar_editor_style()` and `start_decoration_refresh()`.

8. **Chat streaming UX & typewriter + scroll behavior**  
   - Old: `_update_ask_button_state`, `scroll_output_to_bottom`, `scroll_output_to_bottom_if_following`, `_on_chat_scroll_value_changed`, `_deferred_smooth_scroll_chat_to_bottom`, `_animate_ask_panel_in`, `should_typewriter_assistant_at_index`, `get_typewriter_reasoning_slice`, `get_typewriter_plain_slice`, `_on_typewriter_timer_timeout` all lived in `ai_dock.gd`.  
   - New: all of these have been moved into `dock/chat_ux.gd` (`GodotAIChatUX`).  
   - `ai_dock.gd` now calls:
     - `_chat_ux.update_ask_button_state()`
     - `_chat_ux.scroll_output_to_bottom()`
     - `_chat_ux.scroll_output_to_bottom_if_following()`
     - `_chat_ux.on_chat_scroll_value_changed()`
     - `await _chat_ux.deferred_smooth_scroll_chat_to_bottom()`
     - `_chat_ux.animate_ask_panel_in(panel)`
     - `_chat_ux.should_typewriter_assistant_at_index(idx)`
     - `_chat_ux.get_typewriter_reasoning_slice(reasoning)`
     - `_chat_ux.get_typewriter_plain_slice(text, reasoning_len)`
     - `_chat_ux.on_typewriter_timer_timeout()`

9. **Prompt + focus + ESC behavior**  
   - Old: `_on_prompt_text_edit_gui_input`, `_on_interject_stopped`, `_focus_prompt_input`, `_on_dock_focus_entered`, `_on_dock_focus_exited`, `_check_unfocus_after_focus_exited`, `_input` (ESC handling) were embedded in `ai_dock.gd`.  
   - New: moved into `dock/chat_ux.gd` as:
     - `on_prompt_text_edit_gui_input(event)`
     - `on_interject_stopped()`
     - `focus_prompt_input()`
     - `on_dock_focus_entered()`
     - `on_dock_focus_exited()`
     - `check_unfocus_after_focus_exited()`
     - `on_input(event)`
   - `_ready()` now connects:
     - The dock’s `focus_entered` / `TabContainer` focus signals to `chat_ux`.
     - `prompt_text_edit.gui_input` to `chat_ux` via a lambda.

10. **Chat/session state**  
   - All “ensure chat exists and has messages” logic is duplicated out of `ai_dock.gd` and lives in:
     - `chat/chat_state.gd` – tab logic + default chat.
     - `core/stores/chat_session_store.gd` – ephemeral UI state.
     - `ai_dock.gd` keeps thin wrappers (`ensure_chat_has_messages()`, `ensure_chat_has_messages_internal()`) that forward into `chat_state`.

At this point `ai_dock.gd` is primarily:

- Node references (`@onready var ...`)
- A set of small public helpers for controllers/stores.
- `_ready()` wiring up:
  - Signals from `ui/ai_surface.tscn`.
  - Delegations into `chat`, `dock`, `backend`, `ui_tabs`, and `editor` helpers.
- Some glue for settings, changes/history, and top‑level chat/tab orchestration.

The file is **substantially smaller than the original**, but still above the 1000 line target (remaining work below).

---

## 4. Remaining refactor work (to finish)

### 4.1 Reduce `ai_dock.gd` below 1000 lines

As of the latest changes, `ai_dock.gd` still contains:

- Settings tab glue (e.g. `_apply_settings_from_config`, `_on_settings_changed`, backend profile/model wiring).
- Changes/history tab glue around:
  - `_delete_chat_at_index`
  - `_update_chat_tab_close_visibility`
  - `_on_main_tab_changed`
  - `unfocus_timeline_edit`, `focus_on_timeline_edit` (and related pieces).
- Some backend/tool/logging passthrough that could be moved to services.

**Recommended next steps**:

1. **Settings tab controller refinement**
   - The majority of Settings behavior is already in `ui_tabs/settings_tab.gd`.
   - Goal: keep `ai_dock.gd`’s settings methods as thin as possible.
   - If you find any non‑trivial settings logic still in `ai_dock.gd`, prefer:
     - Move it into `ui_tabs/settings_tab.gd` or a tiny controller under `dock/`.
     - Have `ai_dock.gd` call something like `_settings_tab.apply_display_settings()` instead.

2. **Changes/history tab orchestration**
   - `ui_tabs/changes_tab.gd` and `ui_tabs/history_tab.gd` already exist.
   - Move behavior that calculates or mutates changes/history state into:
     - `ui_tabs/*` where it is purely view logic.
     - `ai_edit_store.gd` where it is data logic.
   - Leave `ai_dock.gd` responsible only for:
     - Determining which tab is active.
     - Calling into `_changes_tab.render_changes_tab()`, `_history_tab.refresh_usage()`.

3. **Editor integration glue**
   - Keep anything that actually manipulates the editor (opening files, focusing nodes, applying decorations) inside:
     - `editor/*` (e.g. `editor_decorator.gd`, `follow_editor.gd`).
   - `ai_dock.gd` should:
     - Call `apply_editor_decorations()` and simple wrappers.
     - Avoid new direct editor logic.

Every time you move a cluster of logic out of `ai_dock.gd`:

- **Step 1**: Create/update a helper in the right folder:
  - `dock/` for dock‑specific controllers.
  - `chat/` for chat representation behavior.
  - `ui_tabs/` for tab‑specific UI logic.
  - `editor/` for editor‑side operations.
- **Step 2**: Provide only the minimal public helpers on `GodotAIDock` that the helper needs (`get_*`, `set_*`).
- **Step 3**: Delete the original methods from `ai_dock.gd` and wire signal connections to the new helper.
- **Step 4**: Run:
  - `cd rag_service`
  - `.\scripts\gdlint.ps1 -Files "..\godot_plugin\addons\godot_ai_assistant\ai_dock.gd","..\godot_plugin\addons\godot_ai_assistant\<new_or_changed>.gd"`

### 4.2 Keep MVC boundaries strict

When adding new features or refactoring further:

- **Stores (`core/*`, `core/stores/*`, `ai_edit_store.gd`, `settings.gd`)**:
  - No `Control` / `Node` dependencies.
  - No calls to `EditorInterface` or `EditorFileSystem`.
  - Only hold data and expose methods that mutate that data.

- **Views (`ui/*`, `ui/components/*`, `ui_tabs/*`)**:
  - Node refs (`@onready`).
  - Signal emission (connect to controller methods via `ai_dock.gd` or small lambdas).
  - No HTTP, no lint, no tool execution, no direct file IO.

- **Controllers/Services (`dock/*`, `chat/*`, `backend/*`, `tools/*`, `editor/*`, `services/*`)**:
  - Do the “work”: HTTP, backend calls, linting, editor tool execution, decoration updates.
  - May depend on both stores and views, but must be **small and focused**.
  - Avoid making a new “god helper” – if a controller grows too big, split it again.

---

## 5. How to work on this plugin going forward

1. **Before editing**:
   - Skim this file and `CONTEXT.md` to locate the right layer:
     - Is your change about data/state? → store.
     - Is it about drawing/updating UI only? → view (`ui` or `ui_tabs`).
     - Is it about backend/editor IO or orchestration? → controller/service.

2. **When adding new functionality**:
   - Prefer:
     - New helper in `dock/` or `chat/` over adding logic into `ai_dock.gd`.
     - New small scene under `ui/components/` plus a small script, over writing layout procedurally.

3. **After editing any `.gd` in the plugin**:
   - From repo root:
     - `cd rag_service`
     - `.\scripts\gdlint.ps1 -Files "..\godot_plugin\addons\godot_ai_assistant\<file>.gd"`
   - Fix any reported issues before committing.

4. **If the plugin fails to load or acts strangely**:
   - Run a quick Godot script check:
     - `cd C:\Github\godot-llm`
     - `.\\godot\\bin\\godot.windows.editor.x86_64.exe --headless --editor --path .\\godot_plugin --check-only addons/godot_ai_assistant/godot_ai_assistant.gd`
   - Look for the **first script error** and resolve it (often a dependency script).

---

## 6. Status summary

- `ai_dock.gd`:
  - No longer a full “god object” – responsibilities have been split out into `dock/*`, `chat/*`, `ui_tabs/*`, `backend/*`, `editor/*`, and `services/*`.
  - Now under the 1000‑line target and treated strictly as a composition‑root + wiring layer.
- MVC compliance:
  - Structure is aligned with the MVC‑ish architecture described above.
  - When adding new behavior, prefer new helpers (`dock/*`, `chat/*`, `ui_tabs/*`, `editor/*`, `services/*`) instead of growing `ai_dock.gd`.

If you complete another major extraction from `ai_dock.gd`, please:

- Note it in this file (what moved where).
- Update `CONTEXT.md` if folder responsibilities changed.
- Ensure lint + Godot script checks still pass.

