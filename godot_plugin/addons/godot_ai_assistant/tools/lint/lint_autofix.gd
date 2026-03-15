@tool
extends RefCounted
class_name GodotAILintAutofix

## Lint-and-autofix loop: run lint via backend, ask backend for fixes, apply tool_calls, retry.

static func lint_and_autofix_return_ok(
	dock: GodotAIDock, res_path: String, max_rounds: int
) -> bool:
	var original_before_any_fix := GodotAIServerLint.read_text_res(res_path)
	var first_failure_output := ""

	for attempt in range(max_rounds):
		var lint := await GodotAIServerLint.run_lint(dock, res_path)
		var ok: bool = lint.get("ok", false)
		var lint_out := str(lint.get("output", "")).strip_edges()
		if ok:
			if not first_failure_output.is_empty():
				var final_after := GodotAIServerLint.read_text_res(res_path)
				if not final_after.is_empty() and final_after != original_before_any_fix:
					await dock.get_backend_api().post_lint_fix_to_backend(
						res_path, first_failure_output, original_before_any_fix, final_after,
						dock.get_last_tool_prompt()
					)
			return true
		var lint_output: String = lint_out if not lint_out.is_empty() else "Lint failed but produced no output."
		if first_failure_output.is_empty():
			first_failure_output = lint_output
		var fix_question := (
			"Fix the lint errors in this file and only change what is necessary.\n"
			+ "Godot reports one error at a time. Lint will be re-run after each fix. If more errors remain, you will receive another message with the next error. Fix the current error; more may follow.\n\n"
			+ "File: %s\n"
			+ "Project root: res://\n"
			+ "Lint output:\n%s\n\n"
			+ "Use editor tools (apply_patch or write_file) to update the file.\n"
			+ "After making edits, assume lint will be rerun; keep iterating until it passes."
		) % [res_path, lint_output]
		var file_content := GodotAIServerLint.read_text_res(res_path)
		var fix_resp := await dock.query_backend_for_tools(
			fix_question, lint_output, res_path, file_content
		)
		var tool_calls := fix_resp.get("tool_calls", [])
		if tool_calls is Array and tool_calls.size() > 0 and dock.get_tool_executor():
			await dock.run_editor_actions_async(
				tool_calls, false, "lint_fix", fix_question, lint_output, ""
			)
		else:
			var err_msg := (
				"Auto-lint failed on %s (attempt %d/%d); no tool calls to fix.\n\nLint:\n%s"
				% [res_path, attempt + 1, max_rounds, lint_output]
			)
			dock.post_system_message(err_msg)
			return false
	var final_lint := await GodotAIServerLint.run_lint(dock, res_path)
	return bool(final_lint.get("ok", false))


static func lint_and_autofix(dock: GodotAIDock, res_path: String, max_rounds: int) -> void:
	for attempt in range(max_rounds):
		var lint := await GodotAIServerLint.run_lint(dock, res_path)
		var ok: bool = lint.get("ok", false)
		var lint_out := str(lint.get("output", "")).strip_edges()
		if ok:
			return

		var lint_output: String = lint_out if not lint_out.is_empty() else "Lint failed but produced no output."
		var fix_question := (
			"Fix the lint errors in this file and only change what is necessary.\n"
			+ "Godot reports one error at a time. Lint will be re-run after each fix. If more errors remain, you will receive another message with the next error. Fix the current error; more may follow.\n\n"
			+ "File: %s\n"
			+ "Project root: res://\n"
			+ "Lint output:\n%s\n\n"
			+ "Use editor tools (apply_patch or write_file) to update the file.\n"
			+ "After making edits, assume lint will be rerun; keep iterating until it passes."
		) % [res_path, lint_output]
		var file_content := GodotAIServerLint.read_text_res(res_path)
		var fix_resp := await dock.query_backend_for_tools(
			fix_question, lint_output, res_path, file_content
		)
		var tool_calls := fix_resp.get("tool_calls", [])
		if tool_calls is Array and tool_calls.size() > 0 and dock.get_tool_executor():
			await dock.run_editor_actions_async(
				tool_calls, false, "lint_fix", fix_question, lint_output, ""
			)
		else:
			var err_msg2 := (
				"Auto-lint failed on %s (attempt %d/%d); no tool calls.\n\nLint:\n%s"
				% [res_path, attempt + 1, max_rounds, lint_output]
			)
			dock.post_system_message(err_msg2)
			return

	var final_lint := await GodotAIServerLint.run_lint(dock, res_path)
	var final_output: String = str(final_lint.get("output", "")).strip_edges()
	var give_up_msg := "Gave up after %d attempts; lint still failing for %s.\n\nLast:\n%s" % [
		max_rounds, res_path, final_output
	]
	dock.post_system_message(give_up_msg)
