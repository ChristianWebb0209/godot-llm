@tool
extends RefCounted
class_name GodotAIHistoryTab

## Edit History tab: refresh list, render list, item selected detail, undo.
## Renders each entry with +x (green), -y (red), and "x time ago" (right-aligned).

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


## Returns "N min ago", "N hours ago", "N days ago", or "N weeks ago" from unix timestamp.
static func _time_ago_string(unix_ts: float) -> String:
	if unix_ts <= 0:
		return ""
	var now := Time.get_unix_time_from_system()
	var diff := int(now - unix_ts)
	if diff < 0:
		return ""
	if diff < 60:
		return "just now"
	if diff < 3600:
		var m := diff / 60
		return "%d min ago" % m if m == 1 else "%d mins ago" % m
	if diff < 86400:
		var h := diff / 3600
		return "1 hour ago" if h == 1 else "%d hours ago" % h
	if diff < 604800:
		var d := diff / 86400
		return "1 day ago" if d == 1 else "%d days ago" % d
	var w := diff / 604800
	return "1 week ago" if w == 1 else "%d weeks ago" % w


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
		_dock.history_usage_label.text = "Tokens: -  |  Est. cost: -"
		return
	var total_prompt := int(data.get("total_prompt_tokens", 0))
	var total_completion := int(data.get("total_completion_tokens", 0))
	var total_tokens := int(data.get("total_tokens", 0))
	if total_tokens <= 0:
		total_tokens = total_prompt + total_completion
	var cost := float(data.get("estimated_cost_usd", 0.0))
	_dock.history_usage_label.text = "Tokens: %d (in: %d, out: %d)  |  Est. cost: $%.4f" % [total_tokens, total_prompt, total_completion, cost]


func render_history_list() -> void:
	_dock.set_selected_history_edit_id(-1)
	if _dock.history_detail_label:
		_dock.history_detail_label.text = ""
	var events: Array = _dock.get_history_events()
	if _dock.history_list_vbox:
		# Custom rows: entry text, +x (green), -y (red), time ago (right-aligned).
		for c in _dock.history_list_vbox.get_children():
			c.queue_free()
		if _dock.history_scroll:
			_dock.history_scroll.visible = true
		if _dock.timeline_list:
			_dock.timeline_list.visible = false
		var idx := 0
		for e in events:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var row := _make_history_row(e, idx)
			if row:
				_dock.history_list_vbox.add_child(row)
			idx += 1
		return
	if not _dock.history_list:
		return
	_dock.history_list.clear()
	for e in events:
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
		var time_ago := _time_ago_string(ts)
		var time_part := ("[%s]  " % time_str) if not time_str.is_empty() else ""
		var label := "%s#%d  %d file(s)  +%d -%d  %s  (%s)  %s" % [
			time_part, id_val, file_count, add_total, rem_total, summary, trigger, time_ago
		]
		_dock.history_list.add_item(label)


func _make_history_row(e: Dictionary, index: int) -> HBoxContainer:
	var id_val := int(e.get("id", -1))
	var summary := str(e.get("summary", "")).strip_edges()
	var ts := float(e.get("timestamp", 0.0))
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
	var time_ago := _time_ago_string(ts)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var main_btn := Button.new()
	main_btn.flat = true
	main_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var main_text := "#%d  %s" % [id_val, summary] if not summary.is_empty() else "#%d" % id_val
	if file_count > 0:
		main_text += "  (%d file(s))" % file_count
	main_btn.text = main_text
	main_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_btn.pressed.connect(_on_history_row_pressed.bind(index))
	row.add_child(main_btn)
	var add_lbl := Label.new()
	add_lbl.text = "+%d" % add_total
	add_lbl.add_theme_color_override("font_color", Color(0.35, 0.8, 0.4))
	row.add_child(add_lbl)
	var rem_lbl := Label.new()
	rem_lbl.text = "-%d" % rem_total
	rem_lbl.add_theme_color_override("font_color", Color(0.95, 0.4, 0.35))
	row.add_child(rem_lbl)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var time_lbl := Label.new()
	time_lbl.text = time_ago
	time_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	row.add_child(time_lbl)
	return row


func _on_history_row_pressed(index: int) -> void:
	on_history_item_selected(index)


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
				parts.append("\n  - %s  (%s)  [+%d -%d]" % [fp, ct, add_n, rem_n])
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
