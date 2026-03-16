### Godot AI Assistant plugin – working notes

This file captures practical context for developing and debugging the `godot_ai_assistant` Godot 4.6 plugin.

---

### 1. High-level structure

- **Entry plugin**: `godot_ai_assistant.gd` (`@tool`, extends `EditorPlugin`).
  - Creates a shared `GodotAIAgentStore` on `_enter_tree`.
  - Instantiates the dock UI from `ai_dock.tscn` and script `ai_dock.gd` and adds it with:
    - `add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)` (right upper dock slot).
  - Optionally adds the **Agent Manager** main-screen panel from `agent_manager_panel.tscn` / `agent_manager_panel.gd` via `_add_agent_manager_panel`.
  - Registers various context-menu plugins for “Add to context” in Script, SceneTree, and FileSystem docks.

- **Dock (right side)**:
  - Scene: `ai_dock.tscn`.
  - Script: `ai_dock.gd` (`class_name GodotAIDock`, `@tool`).
  - Tabs inside `TabContainer`:
    - `Chat`: main conversational UI, context viewer, pinned context row, IO split (chat vs prompt), bottom “Model / Context viewer” row.
    - `Changes`: pending changes + history timeline (uses `GodotAIEditStore` and `GodotAIDiffReview`).
    - `Settings`: display and backend settings, indexing status, context windows list.

- **Agent manager (main screen)**:
  - Scene: `agent_manager_panel.tscn`.
  - Script: `agent_manager_panel.gd` (`@tool`, extends `MarginContainer`).
  - Laid out as HSplit with left panel (agents + page nav) and right panel (Chat / Changes / Settings pages).
  - Shares state with the dock via a **single** `GodotAIAgentStore` instance and the same `GodotAIDock`.

---

### 2. Key classes and responsibilities

- `GodotAIDock` (`ai_dock.gd`):
  - Holds references to nearly all UI nodes in the dock and many helper objects:
    - `_settings: GodotAISettings`
    - `_edit_store: GodotAIEditStore`
    - `_decorator: GodotAIEditorDecorator`
    - `_diff_review: GodotAIDiffReview`
    - `_backend_api: GodotAIBackendAPI`
    - `_tool_runner: GodotAIToolRunner`
    - `_chat_state: GodotAIChatState`
    - `_chat_renderer: GodotAIChatRenderer`
    - `_activity_state: GodotAIActivityState`
    - `_changes_tab: GodotAIChangesTab`
    - `_history_tab: GodotAIHistoryTab`
    - `_settings_tab: GodotAISettingsTab`
  - **Public API** used from other scripts:
    - `get_agent_store()`, `set_agent_store(store)`
    - `get_settings()`, `get_edit_store()`, `get_chat_renderer()`
    - `get_changes_tab()`, `get_settings_tab()`
    - `request_backend_lint()`, `query_backend_for_tools()`
    - `run_editor_actions_async()`, `log_edit_event_to_backend()`
    - Various helpers to open diffs, focus editor on files, send lint follow-ups, etc.
  - Manages:
    - Chat tabs (internal `_chats` array or via `_agent_store`).
    - Streaming responses and typewriter effects.
    - Activity / tool-call UI.
    - Context usage and context viewer blocks.
    - Editor decorations and history / changes integration.

- `Agent Manager Panel` (`agent_manager_panel.gd`):
  - Exposes `func set_store_and_dock(store: GodotAIAgentStore, dock: GodotAIDock)`.
    - This is required: `_add_agent_manager_panel()` checks `has_method("set_store_and_dock")` before using the scene.
  - Keeps a second, more “dashboard-like” chat view in sync with the dock:
    - Reads chats from `_store`.
    - Uses `_dock.get_chat_renderer()` to override message list when the Agent Manager is visible.
    - Forwards settings overrides to `_dock.get_settings_tab()` so there is a single source of truth.

---

### 3. Layout rules and recent decisions

**Dock attachment & sizing**
- We currently **do not override** the dock’s size at runtime; we rely on Godot’s dock system:
  - `ai_dock.tscn` sets:
    - `AIDock` root: `layout_mode = 1` (anchors), `anchors_preset = PRESET_FULL_RECT`, `offset_* = 0`, `grow_horizontal/vertical = EXPAND`.
    - `TabContainer`, `Chat` control, and its `VBox` are also full-rect anchored.
  - In `ai_dock.gd::_ready()` we have intentionally **removed** custom `_notification` / `_ensure_fill_parent` resizing. This avoids “half-speed” resizing where the content lags behind the dock.

**Chat tab layout (horizontal behavior)**
- `ChatTabBarRow`:
  - `HBoxContainer` with `size_flags_horizontal = EXPAND_FILL`.
  - `ChatTabBarPanel` (containing `ChatTabBar`) uses `size_flags_horizontal = EXPAND_FILL`, so the tab bar stretches with the row.
  - `NewChatButton` uses `size_flags_horizontal = SIZE_SHRINK_BEGIN (0)`, so it stays at the right side and is the first thing to shrink when width is tight.
  - No extra spacer control is currently used; the layout is simple and relies on the HBox’s natural packing.

- `PromptRow`:
  - `HBoxContainer` with `size_flags_horizontal = EXPAND_FILL`.
  - `PromptTextEdit` uses `size_flags_horizontal = EXPAND_FILL (3)` so it takes as much width as possible.
  - `AskButton` uses `size_flags_horizontal = SIZE_SHRINK_BEGIN (0)` so when the dock narrows, the button and right side shrink first; the prompt remains left-oriented and visible.
  - In `ai_dock.gd::_ready()`, we configure the prompt to **wrap instead of scroll**:
    - `prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY`
    - `prompt_text_edit.scroll_fit_content_height = true`
    - `prompt_text_edit.scroll_past_end_of_file = false`
    - This keeps the prompt visually stable (no internal scrollbars) and prevents horizontal scrolling in the input.

- `BottomRow/ToolRow`:
  - `BottomRow` (`VBoxContainer`) has `size_flags_horizontal = EXPAND_FILL`.
  - `ToolRow` (`HBoxContainer`) also has `size_flags_horizontal = EXPAND_FILL`.
  - `ModelLabel` + `ModelOption` are left-oriented with `size_flags_horizontal = 0` (their size is mostly driven by minimums).
  - `ContextViewerButton` sits to the right with `size_flags_horizontal = 0`; as width shrinks, right-side content is squeezed first.
  - We previously experimented with spacers (`ToolRowSpacer`) but reverted to a simpler layout to avoid unintended blank areas and misalignment.

**General Godot 4 layout notes used here**
- For `Control` nodes:
  - `size_flags_horizontal = 3` → `SIZE_EXPAND_FILL`:
    - Good for main content controls that should take all available space in containers.
  - `size_flags_horizontal = 0` → `SIZE_SHRINK_BEGIN`:
    - Control sits at the start (left in HBox) or end (right in HBox) depending on order; it does not expand, and it is shrunk before expand/fill neighbors when space is limited.
  - Avoid overusing explicit minimum sizes except where needed (buttons, small labels); they can cause early clipping or force scrollbars.
  - When a control is inside an `HBoxContainer`/`VBoxContainer`, the container manages position and size; anchor presets are mostly relevant at higher levels (root, TabContainer, etc.).

---

### 4. Known pitfalls and error patterns

**1. Script parse / load errors cascade into plugin failures**
- If `ai_dock.gd` or `agent_manager_panel.gd` fails to compile:
  - Godot instantiates the scenes as generic `Control` nodes without script methods.
  - Symptoms:
    - In `_add_agent_manager_panel()`: `if not _main_screen_panel.has_method("set_store_and_dock")` will be true, and you’ll see:
      - `Godot AI Assistant: Agent Manager panel missing set_store_and_dock.`
    - Many “Invalid call. Nonexistent function 'get_chat_renderer' in base 'Control (GodotAIDock)'” errors if `GodotAIDock` fails to compile (treated as bare `Control`).
  - Fix strategy:
    - Always resolve the earliest **SCRIPT ERROR: Parse Error** in the Output first.
    - Once scripts compile, disable and re-enable the plugin (Project Settings → Plugins) or restart the editor to clear placeholder instances.

**2. Duplicated variable names in GDScript**
- Godot 4’s typed GDScript is strict about redefinitions.
  - Example previously seen in `agent_manager_panel.gd`:
    - Declared `_toolbar_model_option` at the top, then redeclared it near `_ready()`.
    - Error: `"Variable \"_toolbar_model_option\" has the same name as a previously declared variable."`
  - Fix: keep a **single** declaration and only assign in `_ready()` or helper methods.

**3. Typed inference issues**
- Godot 4 can fail to infer variable types when using `var chat := get_chats()[i]` with a mixed-type Array.
  - Error: `Cannot infer the type of "chat" variable because the value doesn't have a set type.`
  - Fixes used in `ai_dock.gd`:
    - Declare as `Variant` explicitly:
      ```gdscript
      var chat: Variant = get_chats()[chat_index]
      if typeof(chat) != TYPE_DICTIONARY:
      	return
      ```
    - Or use `Dictionary` when type is constrained and known.

**4. Godot 4 notification constants**
- `NOTIFICATION_PARENT_RESIZED` is **not** a valid notification constant; using it caused parse errors.
  - We removed this usage entirely from `ai_dock.gd` and rely on default dock sizing.

---

### 5. Resizing behavior: what *not* to do (lessons learned)

- Avoid:
  - Manually calling `set_size()` / `set_position()` in `_notification` for every resize; in a dock, this can cause the content to “lag” behind the dock edge (appearing to move at half the mouse speed).
  - Over-layering anchors and size flags in conflicting ways (e.g., forcing full rect in code while containers are trying to manage size).

- Prefer:
  - Letting the dock system control the top-level size (`AIDock` + `TabContainer` anchored full rect in the scene).
  - Using `HBoxContainer` / `VBoxContainer` size flags to express “left oriented” vs “right oriented” and which controls should shrink first.
  - For text inputs like the chat prompt:
    - Use wrapping and `scroll_fit_content_height` to avoid horizontal scroll, rather than relying on container shrink behavior alone.

---

### 6. How to safely iterate on the plugin

1. **Edit scene layout** in `ai_dock.tscn` and `agent_manager_panel.tscn`:
   - Prefer changing `size_flags_horizontal/vertical`, `custom_minimum_size`, and container order rather than runtime anchoring hacks.
   - Keep the root controls’ anchors full-rect and offsets at zero so they follow the dock/editor panel.

2. **Edit scripts**:
   - Always check the Godot Output panel for the **first parse error** after script changes.
   - Fix compiler errors in dependency scripts first (e.g., `settings_tab.gd`) because `ai_dock.gd` references their global classes.

3. **Reload plugin**:
   - After nontrivial script edits, disable/enable the “Godot AI Assistant” plugin to clear placeholder instances.

4. **Test resizing and layout**:
   - Resize the right dock rapidly left and right and verify:
     - Chat tab bar, chat scroll, prompt row, and bottom row all move in sync with the dock edge.
     - The prompt input remains visible and does not get an internal scrollbar.

This file should be updated as we refine the layout and behavior of the dock and Agent Manager. When making major changes, add a brief “what changed and why” note here so future work doesn’t reintroduce past issues.

