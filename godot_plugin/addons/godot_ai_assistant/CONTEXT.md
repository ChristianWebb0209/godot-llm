## Godot AI Assistant plugin — onboarding + architecture (current)

This document is the single source of truth for **how the plugin is structured today**.
If something here is wrong, update it immediately (delete stale info; don’t append history).

### Goals

- **Maximum dev velocity** via strict separation of concerns (MVC-ish) and reusable scenes.
- **No god objects**: `ai_dock.gd` must keep shrinking toward the 1000-line cap.
- Prefer **Godot-native composition**: `.tscn` UI components + small scripts over programmatic UI.

### MVC boundary (enforced)

- **Models / Stores (pure state)**
  - Location: `core/*`, `core/stores/*`, `ai_edit_store.gd`, `settings.gd`
  - Rules: no `Node`/`Control` references, no editor mutation, no IO.

- **Views (UI nodes + signals only)**
  - Location: `ui/*.tscn`, `ui/components/*`, `ui_tabs/*`
  - Rules: no backend calls, no tool execution, no file writes, no editor mutation.

- **Controllers / Services (side effects + orchestration)**
  - Location: `dock/*`, `chat/*`, `backend/*`, `tools/*`, `editor/*`, `services/*`
  - Rules: single-purpose files; keep text formatting/presentation close to the renderer, not in backend code.

### What loads what (entrypoints)

- **Plugin entry**: `godot_ai_assistant.gd` (`@tool`, `EditorPlugin`)
  - Creates **one** shared `GodotAIAgentStore`
  - Instantiates **one shared UI scene** twice:
    - Dock surface (right dock)
    - Main-screen surface (editor main panel)

- **Shared UI scene**: `ui/ai_surface.tscn`
  - Script: `ui/ai_surface.gd` (`GodotAISurface`, extends `GodotAIDock`)
  - Variant flag: `layout_variant = DOCK | MAIN_SCREEN`

### Folder map (where to edit)

- `ui/`
  - `ai_surface.tscn`: the single surface scene used everywhere
  - `ai_surface.gd`: tiny layout-variant wrapper (keep small)
  - `components/`
    - `chat_input_bar.tscn` / `.gd`: prompt + model dropdown + send button (reusable)
    - `chat_message_block.tscn` / `.gd`: reusable rendered message block

- `ai_dock.gd` (`GodotAIDock`)
  - The **view composition root**: node refs + signal wiring + delegates to helpers.
  - Should not contain big chunks of business logic; extract into controllers/services.

- `core/`
  - `agent_store.gd`: shared chat list + current chat index (single source of truth)
  - `context_payload.gd`: context building helpers (pure-ish utilities)
  - `backend_client.gd`, `backend_profile.gd`: backend configuration primitives
  - `stores/chat_session_store.gd`: per-session UI state (scroll follow flags, activity)

- `dock/` (controllers for dock-only behaviors)
  - `chat_streaming.gd`: streaming + send pipeline (delegated from dock)
  - `http_request_handler.gd`: non-streaming HTTP completion + health check
  - `tool_follow_up.gd`: tool execution follow-up + lint-fix follow-up loop
  - `pinned_context.gd`: pinned context row state + serialization to context payload
  - `chat_context_menu.gd`: right-click menu actions (copy/export)
  - `context_viewer.gd`: context viewer panel toggle/refresh
  - `editor_chrome.gd`: editor-only theming + decoration refresh timer

- `chat/` (rendering + small chat-specific helpers)
  - `chat_renderer.gd`: incremental render to `chat_message_block` components
  - `markdown_renderer.gd`: markdown → bbcode conversion
  - `chat_state.gd`: tab actions + chat list coordination (works with stores)
  - `activity_state.gd`: activity history / UI data
  - `ask_resolver.gd`: parses assistant “ask” messages into options UI
  - `prompt_input.gd`, `chat_drop_zone.gd`: input + drag/drop adapters for the surface scene

- `ui_tabs/` (tab-level controllers that still read as “view helpers”)
  - `settings_tab.gd`: settings controls sync/apply
  - `changes_tab.gd`: pending/timeline render + revert action
  - `history_tab.gd`: history/indexing UI and refresh
  - `context_menu_add_to_context.gd`: editor context-menu integration plugin

- `backend/`
  - `backend_api.gd`: request building / parsing for backend endpoints
  - `tool_runner.gd`: maps backend tool_calls → executor calls + edit records

- `tools/` (editor-side actions)
  - `editor_tool_executor.gd`: dispatches tool actions to modules
  - `file.gd`, `fs.gd`, `node.gd`, `run.gd`, etc: action implementations
  - `tools/lint/*`: lint capture + autofix helpers (no test harnesses live here)

- `editor/`
  - `editor_decorator.gd`: applies editor decorations (file/node status markers)
  - `diff_review.gd`, `diff_calculator.gd`, `follow_editor.gd`: editor integration helpers

- `services/`
  - `lint_service.gd`: backend lint service wrapper

### Key runtime flows (where to debug)

- **User sends prompt**
  - UI (`chat_input_bar`) → `ai_dock.gd` → `dock/chat_streaming.gd`
  - Streaming chunks update the message list; typewriter UX lives in dock/chat modules.

- **Backend returns tool_calls**
  - `dock/http_request_handler.gd` (non-streaming) or streaming handler
  - `backend/tool_runner.gd` → `tools/editor_tool_executor.gd` → `tools/*` actions
  - Edits stored in `ai_edit_store.gd`, UI updates via `ui_tabs/changes_tab.gd`

- **Lint follow-up loop**
  - When tools edit a file and lint fails, `dock/tool_follow_up.gd` triggers a follow-up request (bounded by cap).

### Development workflow (do this every time)

- **Lint after editing any `.gd`**
  - From repo root:
    - `cd rag_service`
    - `./scripts/gdlint.ps1 -Files \"..\\godot_plugin\\addons\\godot_ai_assistant\\path\\to\\file.gd\"`

- **If the plugin UI turns into a plain Control**
  - Fix the **first parse error** in Output (dependency scripts can cascade).
  - Disable/enable the plugin in Project Settings → Plugins if needed.

