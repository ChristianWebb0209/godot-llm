@tool
extends RefCounted
class_name GodotAIChangesTab

## Pending & Timeline tab: render lists, show diff, revert selected.
## Each timeline entry shows summary, time (e.g. "2m ago"), and lines added/removed (+N -M).

var _dock: GodotAIDock

static func _time_ago_string(unix_ts: int) -> String:
	if unix_ts <= 0:
		return ""
	var now := int(Time.get_unix_time_from_system())
	var diff := now - unix_ts
	if diff < 0:
		return ""
	if diff < 60:
		return "just now"
	if diff < 3600:
		var m := diff / 60
		return "%d min ago" % m if m == 1 else "%d mins ago" % m
	if diff < 86400:
		var h := diff / 3600
		return "1 hr ago" if h == 1 else "%d hrs ago" % h
	if diff < 604800:
		var d := diff / 86400
		return "1 day ago" if d == 1 else "%d days ago" % d
	var w := diff / 604800
	return "1 wk ago" if w == 1 else "%d wks ago" % w

static func _lines_added_removed(old_content: String, new_content: String) -> Vector2i:
	var old_lines := old_content.split("\n", false).size()
	var new_lines := new_content.split("\n", false).size()
	var added := new_lines - old_lines if new_lines > old_lines else 0
	var removed := old_lines - new_lines if old_lines > new_lines else 0
	return Vector2i(added, removed)

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func render_changes_tab() -> void:
	if _dock.get_edit_store() == null:
		return
	if _dock.timeline_list:
		_dock.timeline_list.visible = true
	if _dock.history_scroll:
		_dock.history_scroll.visible = false
	var pl: ItemList = _dock.pending_list
	var tl: ItemList = _dock.timeline_list
	if pl:
		pl.clear()
		_dock.set_selected_pending_id_val("")
		for p in _dock.get_edit_store().pending:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var action_type := str(p.get("action_type", ""))
			var icon := GodotAIEditStore.get_action_icon(action_type)
			var label := (icon + " " if icon else "") + str(p.get("summary", ""))
			pl.add_item(label)
	if tl:
		tl.clear()
		_dock.set_selected_timeline_id_val("")
		for e in _dock.get_edit_store().events:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var action_type := str(e.get("action_type", ""))
			var icon := GodotAIEditStore.get_action_icon(action_type)
			var summary := str(e.get("summary", ""))
			var created_unix := int(e.get("created_unix", 0))
			var old_c := str(e.get("old_content", ""))
			var new_c := str(e.get("new_content", ""))
			var lr := _lines_added_removed(old_c, new_c)
			var time_ago := _time_ago_string(created_unix)
			var extra := ""
			if lr.x > 0 or lr.y > 0:
				extra += "  +%d -%d" % [lr.x, lr.y]
			if not time_ago.is_empty():
				extra += "  " + time_ago
			var label := (icon + " " if icon else "") + summary + extra
			tl.add_item(label)


func on_pending_item_selected(index: int) -> void:
	if _dock.get_edit_store() == null:
		return
	if index < 0 or index >= _dock.get_edit_store().pending.size():
		return
	var p = _dock.get_edit_store().pending[index]
	if typeof(p) != TYPE_DICTIONARY:
		return
	_dock.set_selected_pending_id_val(str(p.get("id", "")))
	var fp := str(p.get("file_path", ""))
	if not fp.is_empty():
		var diff_review = _dock.get_diff_review() if _dock.has_method("get_diff_review") else null
		if diff_review:
			diff_review.open_and_show_diff(fp, str(p.get("old_content", "")), str(p.get("new_content", "")))


func on_timeline_item_selected(index: int) -> void:
	# Side tab: no View buttons; focus automatically on selection.
	focus_on_timeline_edit(index)


func on_revert_selected_pressed() -> void:
	if _dock.get_edit_store() == null or _dock.get_tool_executor() == null:
		return
	if _dock.get_selected_timeline_id().is_empty():
		_dock.set_status("Select a file change in the timeline to revert.")
		return
	var info = _dock.get_edit_store().get_revert_info(_dock.get_selected_timeline_id())
	if info.is_empty():
		_dock.set_status("Selected item cannot be reverted (not a file edit or no previous content).")
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
	else:
		_dock.set_status("Revert failed: %s" % result.get("message", "unknown"))
	render_changes_tab()
	_dock._decorator.apply_decorations()


func unfocus_timeline_edit() -> void:
	_dock.set_selected_timeline_id_val("")
	if _dock.timeline_list:
		_dock.timeline_list.deselect_all()
	var diff_review = _dock.get_diff_review() if _dock.has_method("get_diff_review") else null
	if diff_review:
		diff_review.clear_highlights()


func focus_on_timeline_edit(index: int) -> void:
	if _dock.get_edit_store() == null:
		return
	if index < 0 or index >= _dock.get_edit_store().events.size():
		return
	var e = _dock.get_edit_store().events[index]
	if typeof(e) != TYPE_DICTIONARY:
		return
	_dock.set_selected_timeline_id_val(str(e.get("id", "")))
	# Switch to Changes tab so the user sees the correct tab.
	var changes_tab_idx := -1
	if _dock.tab_container:
		for i in range(_dock.tab_container.get_child_count()):
			if _dock.tab_container.get_child(i).name == "Changes":
				changes_tab_idx = i
				break
	if changes_tab_idx >= 0 and _dock.tab_container.current_tab != changes_tab_idx:
		_dock.tab_container.current_tab = changes_tab_idx
	if str(e.get("kind", "")) == "file":
		var fp := str(e.get("file_path", ""))
		if not fp.is_empty():
			if _dock.has_method("get_editor_interface"):
				GodotAIFollowEditor.focus_editor_on_file(_dock.get_editor_interface(), fp)
			var diff_review = _dock.get_diff_review() if _dock.has_method("get_diff_review") else null
			if diff_review:
				diff_review.open_and_show_diff(fp, str(e.get("old_content", "")), str(e.get("new_content", "")))
