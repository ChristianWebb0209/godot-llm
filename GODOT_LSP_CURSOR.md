# Godot LSP in Cursor (GDScript diagnostics)

This repo contains a Godot project at `godot_plugin/` and ships a Godot editor binary at `godot/bin/`.

The goal is to make Cursor show **continuous GDScript diagnostics** (Problems panel, squiggles, hover/completions)
by connecting to **Godot's built-in GDScript Language Server (LSP)**.

## Prereqs

- Install the VS Code extension **Godot Tools** (`geequlim.godot-tools`) in Cursor.
- Trust the workspace (Cursor restricted mode can disable parts of extensions).

## Workspace config (already in this repo)

- `.vscode/settings.json` sets:
  - `godot-tools.editorPath.godot4` to the bundled Godot executable
  - `godot-tools.projectPath` to `${workspaceFolder}/godot_plugin`
  - `godot-tools.lsp.serverPort` to `6005`
  - `godot-tools.lsp.runAtStartup` to `"lsp4"`

- `.vscode/tasks.json` provides:
  - `GDScript: Start Godot LSP (headless)` (runs on folder open)
  - `GDScript: Lint current file (Godot --check-only)` (parse gate; not a full analyzer)

## How to verify it's working

1. Open any `.gd` file under `godot_plugin/addons/`.
2. Confirm syntax highlighting is active (keywords like `extends`, `func` should be colored).
3. Introduce an obvious error (e.g. `if true` without `:`) and check:
   - **Problems** panel shows a diagnostic for that file.
   - Hover/completions work (e.g. typing `Node.` shows members).

## Troubleshooting

- **No highlighting (all white text)**:
  - Confirm the language mode in the status bar is `GDScript`.
  - Confirm **Godot Tools** is enabled for the workspace.

- **LSP won't connect**:
  - Ensure nothing else is using port `6005`.
  - Try changing both settings to a different port:
    - `godot-tools.lsp.serverPort`
    - (legacy) `godot_tools.gdscript_lsp_server_port`

- **Nested project not detected**:
  - Confirm `godot-tools.projectPath` is `${workspaceFolder}/godot_plugin`.

- **Headless LSP task exits immediately**:
  - Prefer the extension's `godot-tools.lsp.runAtStartup = \"lsp4\"` behavior.
  - You can also run Godot with a visible editor (`--editor --path godot_plugin`) and let Cursor attach.

