@tool
extends RefCounted
class_name GodotAIEditorErrors

## Return current editor Errors/Warnings. Godot does not expose the panel directly; we return a hint and optional log.

static func execute_check_errors(executor: GodotAIEditorToolExecutor, _output: Dictionary) -> Dictionary:
	# Godot 4 does not expose the Errors/Debugger panel content via a public API.
	# The user can use lint_file for script errors. We return a helpful message.
	return {
		"success": true,
		"message": "Editor errors are shown in the Output/Debugger panel. Use lint_file(path) to check script errors for a specific file.",
		"errors": [],
	}
