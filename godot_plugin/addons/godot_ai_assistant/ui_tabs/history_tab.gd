@tool
extends RefCounted
class_name GodotAIHistoryTab

## Edit History tab: refresh list, render list, item selected detail, undo.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func refresh_history() -> void:
	var url := "%s/edit_events/list?limit=500" % _dock.rag_service_url
	var data := await _dock.query_backend_json(url, HTTPClient.METHOD_GET, "")
	if typeof(data) != TYPE_DICTIONARY:
		return
	var events = data.get("events", [])
	if events is Array:
		_dock.set_history_events_arr(events)
	render_history_list()
	await refresh_usage()


func refresh_usage() -> void:
	if not _dock.history_usage_label:
		return
	var url := "%s/usage" % _dock.rag_service_url
	var data := await _dock.query_backend_json(url, HTTPClient.METHOD_GET, "")
	if typeof(data) != TYPE_DICTIONARY or not data.get("ok", false):
		_dock.history_usage_label.text = "Tokens: —  |  Est. cost: —"
		return
	var total_prompt := int(data.get("total_prompt_tokens", 0))
	var total_completion := int(data.get("total_completion_tokens", 0))
	var total_tokens := int(data.get("total_tokens", 0))
	if total_tokens <= 0:
		total_tokens = total_prompt + total_completion
	var cost := float(data.get("estimated_cost_usd", 0.0))
	_dock.history_usage_label.text = "Tokens: %d (in: %d, out: %d)  |  Est. cost: $%.4f" % [total_tokens, total_prompt, total_completion, cost]


func render_history_list() -> void:
	if not _dock.history_list:
		return
	_dock.history_list.clear()
	_dock.set_selected_history_edit_id(-1)
	if _dock.history_detail_label:
		_dock.history_detail_label.text = ""
	for e in _dock.get_history_events():
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id_val := int(e.get("id", -1))
		var summary := str(e.get("summary", ""))
		var trigger := str(e.get("trigger", ""))
		var ts := float(e.get("timestamp", 0.0))
		var time_str := Time.get_datetime_string_from_unix_time(int(ts)) if ts > 0 else ""
		var changes = e.get("changes", [])
		var add_total := 0
		var rem_total := 0
		var file_count := 0
		if changes is Array:
			file_count = changes.size()
			for c in changes:
				if typeof(c) == TYPE_DICTIONARY:
					add_total += int(c.get("lines_added", 0))
					rem_total += int(c.get("lines_removed", 0))
		var time_part := ("[%s]  " % time_str) if not time_str.is_empty() else ""
		var label := "%s#%d  %d file(s)  [+%d -%d]  %s  (%s)" % [
			time_part, id_val, file_count, add_total, rem_total, summary, trigger
		]
		_dock.history_list.add_item(label)


func on_history_item_selected(index: int) -> void:
	if index < 0 or index >= _dock.get_history_events().size():
		return
	var e = _dock.get_history_events()[index]
	if typeof(e) != TYPE_DICTIONARY:
		return
	_dock.set_selected_history_edit_id(int(e.get("id", -1)))
	if _dock.history_detail_label:
		_dock.history_detail_label.text = ""
		var parts: Array[String] = []
		parts.append("[b]Edit #%d[/b]\n" % _dock.get_selected_history_edit_id())
		var ts := float(e.get("timestamp", 0.0))
		if ts > 0:
			parts.append("[b]Timestamp:[/b] %s\n" % Time.get_datetime_string_from_unix_time(int(ts)))
		parts.append("[b]Summary:[/b] %s\n" % str(e.get("summary", "")))
		parts.append("[b]Trigger:[/b] %s\n" % str(e.get("trigger", "")))
		var changes = e.get("changes", [])
		if changes is Array and changes.size() > 0:
			parts.append("\n[b]Files changed:[/b]")
			for c in changes:
				if typeof(c) != TYPE_DICTIONARY:
					continue
				var fp := str(c.get("file_path", ""))
				var ct := str(c.get("change_type", "modify"))
				var add_n := int(c.get("lines_added", 0))
				var rem_n := int(c.get("lines_removed", 0))
				parts.append("\n  • %s  (%s)  [+%d -%d]" % [fp, ct, add_n, rem_n])
				var diff := str(c.get("diff", ""))
				if not diff.is_empty():
					parts.append("\n  [code]" + _dock.escape_bbcode(diff) + "[/code]")
			parts.append("")
		var prompt_text := str(e.get("prompt", ""))
		if not prompt_text.is_empty():
			parts.append("\n[b]Prompt:[/b]\n[code]" + _dock.escape_bbcode(prompt_text) + "[/code]\n")
		var semantic := str(e.get("semantic_summary", ""))
		if not semantic.is_empty():
			parts.append("\n[b]Summary (AI):[/b] %s\n" % _dock.escape_bbcode(semantic))
		var lint_before := str(e.get("lint_errors_before", ""))
		if not lint_before.is_empty():
			parts.append("\n[b]Lint before:[/b]\n[code]" + _dock.escape_bbcode(lint_before) + "[/code]\n")
		var lint_after := str(e.get("lint_errors_after", ""))
		if not lint_after.is_empty():
			parts.append("\n[b]Lint after:[/b]\n[code]" + _dock.escape_bbcode(lint_after) + "[/code]\n")
		_dock.history_detail_label.bbcode_enabled = true
		_dock.history_detail_label.text = "\n".join(parts)


func on_history_undo_pressed() -> void:
	if _dock.get_selected_history_edit_id() < 0:
		return
	var edit_id := _dock.get_selected_history_edit_id()
	var endpoint := "%s/edit_events/undo/%d" % [_dock.rag_service_url, edit_id]
	var data := await _dock.query_backend_json(endpoint, HTTPClient.METHOD_POST, "{}")
	if typeof(data) != TYPE_DICTIONARY:
		return
	var tool_calls = data.get("tool_calls", [])
	if tool_calls is Array and tool_calls.size() > 0 and _dock.get_tool_executor():
		await _dock.run_editor_actions_async(tool_calls, false, "undo", "Undo edit #%d" % edit_id)
		refresh_history()
