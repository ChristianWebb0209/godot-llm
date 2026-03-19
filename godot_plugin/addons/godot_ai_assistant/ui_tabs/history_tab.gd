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


const MAX_DIFF_CHARS := 12000

static func _lines_added_removed(old_content: String, new_content: String) -> Vector2i:
	var old_lines := old_content.split("\n", false).size()
	var new_lines := new_content.split("\n", false).size()
	var added := new_lines - old_lines if new_lines > old_lines else 0
	var removed := old_lines - new_lines if old_lines > new_lines else 0
	return Vector2i(added, removed)

static func _format_old_new_diff(old_content: String, new_content: String) -> String:
	var old_t := str(old_content)
	var new_t := str(new_content)
	if old_t.length() > MAX_DIFF_CHARS:
		old_t = old_t.substr(0, MAX_DIFF_CHARS) + "\n[...truncated...]"
	if new_t.length() > MAX_DIFF_CHARS:
		new_t = new_t.substr(0, MAX_DIFF_CHARS) + "\n[...truncated...]"
	return "--- old\n+++ new\n" + old_t + "\n---\n" + new_t


func refresh_history() -> void:
	var store := _dock.get_edit_store()
	if store == null:
		return

	var out: Array = []
	# Local edit store events are newest-first and are per-file-change.
	# Convert them into the simplified history event shape this tab renders.
	for ev in store.events:
		if typeof(ev) != TYPE_DICTIONARY:
			continue
		if str(ev.get("kind", "")) != "file":
			continue
		var fp := str(ev.get("file_path", ""))
		if fp.is_empty():
			continue

		var old_c := str(ev.get("old_content", ""))
		var new_c := str(ev.get("new_content", ""))
		var lr := _lines_added_removed(old_c, new_c)
		var id_str := str(ev.get("id", ""))
		var ts := float(ev.get("created_unix", 0))
		var summary := str(ev.get("summary", ""))
		var ct := str(ev.get("change_type", "modify"))
		var diff := _format_old_new_diff(old_c, new_c)

		out.append({
			"id": id_str,
			"timestamp": ts,
			"actor": "ai",
			"trigger": "",
			"summary": summary,
			"changes": [
				{
					"file_path": fp,
					"change_type": ct,
					"diff": diff,
					"lines_added": int(lr.x),
					"lines_removed": int(lr.y),
				},
			],
			"prompt": "",
			"semantic_summary": "",
			"lint_errors_before": "",
			"lint_errors_after": "",
		})

		if out.size() >= 500:
			break

	_dock.set_history_events_arr(out)
	_dock.set_selected_history_edit_id("")
	render_history_list()
	refresh_usage()


func refresh_usage() -> void:
	if not _dock.history_usage_label:
		return

	if not _dock.has_method("get_usage_store"):
		_dock.history_usage_label.text = "Tokens: -  |  Est. cost: -"
		return
	var store = _dock.get_usage_store()
	if store == null:
		_dock.history_usage_label.text = "Tokens: -  |  Est. cost: -"
		return

	var totals: Dictionary = store.get_usage_totals()
	var total_prompt := int(totals.get("total_prompt_tokens", 0))
	var total_completion := int(totals.get("total_completion_tokens", 0))
	var total_tokens := int(totals.get("total_tokens", total_prompt + total_completion))
	var cost := float(totals.get("estimated_cost_usd", 0.0))
	if total_tokens <= 0:
		_dock.history_usage_label.text = "Tokens: -  |  Est. cost: -"
		return

	_dock.history_usage_label.text = "Tokens: %d (in: %d, out: %d)  |  Est. cost: $%.4f" % [
		total_tokens, total_prompt, total_completion, cost
	]


func render_history_list() -> void:
	_dock.set_selected_history_edit_id("")
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
		var id_str := str(e.get("id", ""))
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
		var label := "%s#%s  %d file(s)  +%d -%d  %s  (%s)  %s" % [
			time_part, id_str, file_count, add_total, rem_total, summary, trigger, time_ago
		]
		_dock.history_list.add_item(label)


func _make_history_row(e: Dictionary, index: int) -> HBoxContainer:
	var id_str := str(e.get("id", ""))
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
	var main_text := "#%s  %s" % [id_str, summary] if not summary.is_empty() else "#%s" % id_str
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
	_dock.set_selected_history_edit_id(str(e.get("id", "")))
	if _dock.history_detail_label:
		_dock.history_detail_label.text = ""
		var parts: Array[String] = []
		parts.append("[b]Edit #%s[/b]\n" % _dock.get_selected_history_edit_id())
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
	if _dock.get_edit_store() == null or _dock.get_tool_executor() == null:
		return
	var edit_id := _dock.get_selected_history_edit_id()
	if edit_id.is_empty():
		return

	var info := _dock.get_edit_store().get_revert_info(edit_id)
	if info.is_empty():
		_dock.set_status("Selected item cannot be reverted (no previous content).")
		return

	var path := str(info.get("file_path", ""))
	var old_content := str(info.get("old_content", ""))
	_dock.set_status("Reverting: %s..." % path)

	var result: Dictionary = _dock.get_tool_executor().execute({
		"execute_on_client": true,
		"action": "write_file",
		"path": path,
		"content": old_content,
	})

	if result.get("success", false):
		_dock.get_edit_store().clear_file_status(path)
		_dock.set_status("Reverted: %s" % path)
		if _dock.has_method("get_changes_tab"):
			_dock.get_changes_tab().render_changes_tab()
		if _dock._decorator:
			_dock._decorator.apply_decorations()
	else:
		_dock.set_status("Revert failed: %s" % result.get("message", "unknown"))

	refresh_history()
