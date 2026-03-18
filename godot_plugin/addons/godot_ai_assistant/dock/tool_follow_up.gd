@tool
extends RefCounted
class_name GodotAIToolFollowUp

## Controller: runs post-tool-call follow-ups (lint + bounded auto-fix follow-up prompts).

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func run_editor_actions_then_lint_follow_up(
	tool_calls: Array,
	proposal_mode: bool,
	trigger: String = "",
	prompt: String = "",
	lint_errors_before: String = "",
	lint_errors_after: String = ""
) -> void:
	await _dock.run_editor_actions_async(tool_calls, proposal_mode, trigger, prompt, lint_errors_before, lint_errors_after)


func send_lint_fix_follow_up(res_path: String, lint_output: String) -> void:
	if res_path.is_empty() or lint_output.is_empty():
		return
	if _dock.get_lint_follow_up_count_this_turn() >= _dock.get_lint_follow_up_cap():
		return
	_dock.increment_lint_follow_up_count()
	_dock.set_last_lint_result(res_path, lint_output)
	_dock.ensure_chat_has_messages_internal()

	var follow_up_msg := "Fix the remaining errors in this file."
	if _dock.get_lint_follow_up_count_this_turn() > 1:
		follow_up_msg = "Fix the remaining errors (round %d)." % _dock.get_lint_follow_up_count_this_turn()

	_dock.get_chats()[_dock.get_current_chat()]["messages"].append({
		"role": "user",
		"text": follow_up_msg,
		"hidden": true
	})
	_dock.get_chats()[_dock.get_current_chat()]["messages"].append({
		"role": "assistant",
		"text": ""
	})
	_dock.reset_typewriter_for_current_chat()
	_dock.render_chat_log()
	_dock.scroll_output_to_bottom()
	_dock.call_deferred(
		"_deferred_send_question",
		"Fix the remaining lint errors in this file.",
		true,
		res_path,
		"",
		lint_output
	)

