@tool
extends RefCounted
class_name GodotAIToolRunner

## Runs editor tool_calls from the backend: execute loop, format summaries, format chat section.

const _MAX_TOOL_CALLS_PER_RESPONSE := 20

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


static func executor_payload_from_tool_call(tc: Dictionary) -> Dictionary:
	var out = tc.get("output", null)
	if typeof(out) == TYPE_DICTIONARY and out.get("execute_on_client", false):
		return out
	var name_key := tc.get("tool_name", "")
	if name_key.is_empty():
		name_key = tc.get("name", "")
	var args: Dictionary = tc.get("arguments", {})
	if typeof(args) != TYPE_DICTIONARY:
		args = {}
	var payload: Dictionary = {
		"execute_on_client": true,
		"action": str(name_key),
	}
	for k in args:
		payload[k] = args[k]
	return payload


static func format_tool_calls_summaries(tool_calls: Array, dock: GodotAIDock) -> Array:
	var out: Array = []
	for tc in tool_calls:
		if typeof(tc) != TYPE_DICTIONARY:
			out.append("(invalid)")
			continue
		var args: Dictionary = tc.get("arguments", {})
		if typeof(args) != TYPE_DICTIONARY:
			args = {}
		var payload := executor_payload_from_tool_call(tc)
		var action := str(payload.get("action", tc.get("tool_name", "")))
		var parts: Array[String] = [action]
		if action in ["write_file", "append_to_file", "apply_patch", "create_file", "create_script", "delete_file"]:
			var path_val := payload.get("path", args.get("path", ""))
			if path_val:
				parts.append(str(path_val))
		elif action == "create_node":
			var class_name_val := payload.get("class_name", args.get("class_name", ""))
			var parent_val := str(payload.get("parent_path", args.get("parent_path", ""))).strip_edges()
			var scene_val := str(payload.get("scene_path", args.get("scene_path", ""))).strip_edges()
			if class_name_val:
				parts.append(str(class_name_val))
			# Clarify: /root = scene tree root (not res://). Show "under scene root" so users don't look in FileSystem.
			if parent_val.is_empty() or parent_val == "/" or parent_val == "/root":
				parts.append(" under scene root")
			else:
				parts.append(" in " + parent_val)
			if scene_val and scene_val.to_lower() != "current":
				parts.append(" (" + scene_val + ")")
		elif action == "set_node_property":
			var node_val := payload.get("node_path", args.get("node_path", ""))
			var prop_val := payload.get("property", args.get("property", ""))
			if node_val:
				parts.append(str(node_val))
			if prop_val:
				parts.append(" ." + str(prop_val))
		elif action == "modify_attribute":
			var tt := str(payload.get("target_type", args.get("target_type", "")))
			var attr_val := payload.get("attribute", args.get("attribute", ""))
			if tt == "node":
				var node_val := payload.get("node_path", args.get("node_path", ""))
				var scene_val := payload.get("scene_path", args.get("scene_path", ""))
				if scene_val:
					parts.append(str(scene_val))
				if node_val:
					parts.append(" " + str(node_val))
				if attr_val:
					parts.append(" ." + str(attr_val))
			elif tt == "import":
				var path_val := payload.get("path", args.get("path", ""))
				if path_val:
					parts.append(str(path_val))
				if attr_val:
					parts.append(" " + str(attr_val))
		elif action in ["read_file", "lint_file", "list_directory", "search_files"]:
			var path_val := payload.get("path", args.get("path", ""))
			if path_val:
				parts.append(str(path_val))
		elif action == "grep_search":
			var pattern_val := payload.get("pattern", args.get("pattern", args.get("query", "")))
			if pattern_val:
				parts.append(str(pattern_val))
		elif action in ["run_scene", "run_godot_headless"]:
			var scene_val := payload.get("scene_path", args.get("scene_path", args.get("script_path", "")))
			if scene_val:
				parts.append(str(scene_val))
		elif action == "run_terminal_command":
			var cmd_val := payload.get("command", args.get("command", args.get("cmd", "")))
			if cmd_val:
				parts.append(str(cmd_val).substr(0, 40) + ("..." if str(cmd_val).length() > 40 else ""))
		out.append(" ".join(parts))
	return out


func format_editor_actions_chat_section(display_changes: Array) -> String:
	if display_changes.is_empty():
		return ""
	var lines: PackedStringArray = []
	lines.append("")
	lines.append("**Editor actions**")
	lines.append("")
	for c in display_changes:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var action_type := str(c.get("action_type", ""))
		var summary := str(c.get("summary", c.get("message", "")))
		var icon := GodotAIEditStore.get_action_icon(action_type)
		var label := GodotAIEditStore.get_action_label(action_type)
		lines.append("- " + icon + " **" + label + "**: " + summary)
		if action_type == "lint_file" and c.has("message"):
			lines.append(str(c.get("message", "")))
	lines.append("")
	return "\n".join(lines)


func run_editor_actions_async(
	tool_calls: Array,
	_proposal_mode: bool,
	trigger: String = "",
	prompt: String = "",
	lint_errors_before: String = "",
	lint_errors_after: String = ""
) -> void:
	var results: Array[String] = []
	var display_changes: Array = []
	var exec = _dock.get_tool_executor()
	if exec:
		exec.set_follow_agent(
			_dock.follow_agent_check.button_pressed if _dock.follow_agent_check else false
		)
	var edit_records: Array = []
	var effective_trigger := trigger if not trigger.is_empty() else _dock.get_last_tool_trigger()
	var effective_prompt := prompt if not prompt.is_empty() else _dock.get_last_tool_prompt()
	var effective_lint_before := lint_errors_before.strip_edges()
	var effective_lint_after := lint_errors_after.strip_edges()
	var collected_lint_after: Array[String] = []
	var first_failed_lint_path: String = ""
	var first_failed_lint_output: String = ""
	var total := tool_calls.size()
	var skipped := 0
	if total > _MAX_TOOL_CALLS_PER_RESPONSE:
		skipped = total - _MAX_TOOL_CALLS_PER_RESPONSE
		tool_calls = tool_calls.slice(0, _MAX_TOOL_CALLS_PER_RESPONSE)

	if tool_calls.size() > 0:
		_dock.push_activity("Running tools (%d)…" % tool_calls.size())
	for tc in tool_calls:
		if typeof(tc) != TYPE_DICTIONARY:
			continue
		var out := executor_payload_from_tool_call(tc)
		if out.is_empty() or not out.get("execute_on_client", false):
			continue
		var action: String = str(out.get("action", ""))
		if action.is_empty():
			continue
		_dock.push_activity("Tool call: %s" % action)

		if action in ["create_file", "write_file", "append_to_file", "apply_patch", "create_script", "delete_file"]:
			# Only write_file requires non-empty content; create_file may be create-only (then write_file separately).
			if action == "write_file" and str(out.get("content", "")).strip_edges().length() < 10:
				results.append("Error: write_file had no/empty content (model did not generate file). Ask again.")
				continue
			_dock.set_status("Applying: %s..." % str(out.get("path", action)))
			var file_result: Dictionary = await _dock.get_tool_executor().execute_async(out)
			var ok := file_result.get("success", false)
			var msg := file_result.get("message", "OK") if ok else ("Error: %s" % file_result.get("message", "unknown"))
			results.append(msg)
			var rec2 = file_result.get("edit_record", null)
			if rec2 != null and rec2 is Dictionary:
				var rec_dict: Dictionary = rec2
				edit_records.append(rec_dict)
				var path := str(rec_dict.get("file_path", ""))
				var lint_ok := true
				var lint_summary := ""
				if file_result.get("success", false) and _dock.should_lint_path(path):
					_dock.request_editor_filesystem_refresh()
					var local_res: Dictionary = GodotAIServerLint.run_lint_local_only(path)
					lint_ok = local_res.get("ok", true)
					var lint_out := str(local_res.get("output", "")).strip_edges()
					_dock.set_last_lint_result(path, lint_out)
					lint_summary = GodotAIServerLint.format_lint_summary(lint_ok, lint_out)
					if not lint_out.is_empty():
						collected_lint_after.append("%s:\n%s" % [path, lint_out])
					if not lint_ok and first_failed_lint_path.is_empty():
						first_failed_lint_path = path
						first_failed_lint_output = lint_out
				display_changes.append({
					"action_type": rec_dict.get("action_type", action),
					"summary": rec_dict.get("summary", msg),
					"message": msg,
					"file_path": path,
					"lint_ok": lint_ok,
					"lint_summary": lint_summary,
				})
				var store = _dock.get_edit_store()
				if store:
					store.add_applied_file_change(rec_dict, lint_ok, str(rec_dict.get("action_type", "")))
			continue

		if action == "modify_attribute":
			_dock.set_status("Applying: %s..." % action)
			var mod_result: Dictionary = await _dock.get_tool_executor().execute_async(out)
			var mod_ok := mod_result.get("success", false)
			var mod_msg := mod_result.get("message", "OK") if mod_ok else ("Error: %s" % mod_result.get("message", "unknown"))
			results.append(mod_msg)
			var mod_rec = mod_result.get("edit_record", null)
			if mod_rec != null and mod_rec is Dictionary:
				var mr: Dictionary = mod_rec
				display_changes.append({
					"action_type": mr.get("action_type", action),
					"summary": mr.get("summary", mod_msg),
					"message": mod_msg,
				})
				if mr.has("file_path"):
					edit_records.append(mr)
					var path := str(mr.get("file_path", ""))
					var lint_ok := true
					var lint_summary_mod := ""
					if mod_result.get("success", false) and _dock.should_lint_path(path):
						_dock.request_editor_filesystem_refresh()
						var local_res_mod: Dictionary = GodotAIServerLint.run_lint_local_only(path)
						lint_ok = local_res_mod.get("ok", true)
						var lint_out_mod := str(local_res_mod.get("output", "")).strip_edges()
						_dock.set_last_lint_result(path, lint_out_mod)
						lint_summary_mod = GodotAIServerLint.format_lint_summary(lint_ok, lint_out_mod)
						if not lint_out_mod.is_empty():
							collected_lint_after.append("%s:\n%s" % [path, lint_out_mod])
						if not lint_ok and first_failed_lint_path.is_empty():
							first_failed_lint_path = path
							first_failed_lint_output = lint_out_mod
					display_changes[display_changes.size() - 1]["file_path"] = path
					display_changes[display_changes.size() - 1]["lint_ok"] = lint_ok
					display_changes[display_changes.size() - 1]["lint_summary"] = lint_summary_mod
					var store2 = _dock.get_edit_store()
					if store2:
						store2.add_applied_file_change(mr, lint_ok, str(mr.get("action_type", "")))
				elif mr.has("scene_path") and _dock.get_edit_store() and mod_result.get("success", false):
					var scene_path := str(mr.get("scene_path", ""))
					var node_path := str(mr.get("node_path", ""))
					var status := "modified"
					if str(mr.get("action_type", "")) == "create_node":
						status = "created"
					_dock.get_edit_store().add_node_change(
						scene_path, node_path, status, str(mr.get("summary", mod_msg)), str(mr.get("action_type", ""))
					)
			continue

		_dock.set_status("Running: %s..." % action)
		var result: Dictionary
		if action == "lint_file":
			var path_for_lint := str(out.get("path", ""))
			result = await _dock.request_backend_lint(path_for_lint)
		else:
			result = await _dock.get_tool_executor().execute_async(out)
		var res_ok := result.get("success", false)
		var node_msg := result.get("message", "OK") if res_ok else ("Error: %s" % result.get("message", "unknown"))
		results.append(node_msg)
		# So the model sees run output in chat context (write → run → observe → fix)
		if action in ["run_terminal_command", "run_godot_headless", "run_scene"]:
			var run_summary := "Ran: %s" % action
			if action == "run_scene" or action == "run_godot_headless":
				run_summary = "Ran: %s" % str(result.get("scene_path", ""))
			elif action == "run_terminal_command":
				var cmd := str(result.get("command", ""))
				if cmd.length() > 50:
					cmd = cmd.substr(0, 47) + "..."
				run_summary = "Ran: %s" % cmd
			display_changes.append({
				"action_type": action,
				"summary": run_summary,
				"message": node_msg,
			})
		if action == "lint_file":
			var lint_out := str(result.get("output", "")).strip_edges()
			if not lint_out.is_empty():
				display_changes.append({
					"action_type": "lint_file",
					"summary": "Lint: %s" % str(out.get("path", "")),
					"message": "```\n" + lint_out + "\n```",
				})
		var node_rec = result.get("edit_record", null)
		if node_rec != null and node_rec is Dictionary:
			var nr: Dictionary = node_rec
			display_changes.append({
				"action_type": nr.get("action_type", action),
				"summary": nr.get("summary", node_msg),
				"message": node_msg,
			})
			if _dock.get_edit_store() and result.get("success", false):
				var scene_path := str(nr.get("scene_path", ""))
				var node_path := str(nr.get("node_path", ""))
				var status := "modified"
				if str(nr.get("action_type", "")) == "create_node":
					status = "created"
				_dock.get_edit_store().add_node_change(
					scene_path, node_path, status, str(nr.get("summary", node_msg)), str(nr.get("action_type", ""))
				)

	if collected_lint_after.size() > 0:
		effective_lint_after = "\n\n".join(collected_lint_after)
	if edit_records.size() > 0:
		await _dock.log_edit_event_to_backend(
			edit_records, effective_trigger, effective_prompt, effective_lint_before, effective_lint_after
		)
	if skipped > 0:
		_dock.ensure_chat_has_messages()
		var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] += "\n\n_Skipped %d tool call(s). Ask for fewer changes._" % skipped
		_dock.render_chat_log()
	if display_changes.size() > 0:
		_dock.set_status("Editor actions: %d change(s)" % display_changes.size())
		var section: String = format_editor_actions_chat_section(display_changes)
		_dock.ensure_chat_has_messages()
		var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] += section
		_dock.render_chat_log()
	else:
		_dock.set_status("Response received.")
	# If any edited file still has lint errors, send a follow-up so the model fixes remaining errors (repeats until clean or cap).
	if not first_failed_lint_path.is_empty():
		_dock.call_deferred("send_lint_fix_follow_up", first_failed_lint_path, first_failed_lint_output)
	# Clear "Thinking..." / "Using tool: X" so when nothing is happening the activity shows nothing.
	_dock.clear_activity()

	_dock.call_deferred("_render_changes_tab")
	_dock.call_deferred("apply_editor_decorations")
