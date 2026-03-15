@tool
extends RefCounted
class_name GodotAIChangesTab

## Pending & Timeline tab: render lists, show diff, revert selected.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func render_changes_tab() -> void:
	if _dock.get_edit_store() == null:
		return
	if _dock.pending_list:
		_dock.pending_list.clear()
		_dock.set_selected_pending_id_val("")
		for p in _dock.get_edit_store().pending:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var action_type := str(p.get("action_type", ""))
			var icon := GodotAIEditStore.get_action_icon(action_type)
			var label := "%s %s" % [icon, str(p.get("summary", ""))]
			_dock.pending_list.add_item(label)
	if _dock.timeline_list:
		_dock.timeline_list.clear()
		_dock.set_selected_timeline_id_val("")
		for e in _dock.get_edit_store().events:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var action_type := str(e.get("action_type", ""))
			var icon := GodotAIEditStore.get_action_icon(action_type)
			var summary := str(e.get("summary", ""))
			var label := "%s %s" % [icon, summary]
			_dock.timeline_list.add_item(label)
	show_diff("", "")


func show_diff(old_content: String, new_content: String) -> void:
	var diff_path := "TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/RightVBox/DiffSplit"
	var old_te: TextEdit = _dock.diff_old_text if _dock.diff_old_text else _dock.get_node_or_null(
		diff_path + "/OldText"
	) as TextEdit
	var new_te: TextEdit = _dock.diff_new_text if _dock.diff_new_text else _dock.get_node_or_null(
		diff_path + "/NewText"
	) as TextEdit
	if old_te:
		old_te.text = old_content
		old_te.scroll_vertical = 0
		old_te.queue_redraw()
	if new_te:
		new_te.text = new_content
		new_te.scroll_vertical = 0
		new_te.queue_redraw()


func on_pending_item_selected(index: int) -> void:
	if _dock.get_edit_store() == null:
		return
	if index < 0 or index >= _dock.get_edit_store().pending.size():
		return
	var p = _dock.get_edit_store().pending[index]
	if typeof(p) != TYPE_DICTIONARY:
		return
	_dock.set_selected_pending_id_val(str(p.get("id", "")))
	show_diff(str(p.get("old_content", "")), str(p.get("new_content", "")))


func on_timeline_item_selected(index: int) -> void:
	if _dock.get_edit_store() == null:
		return
	if index < 0 or index >= _dock.get_edit_store().events.size():
		return
	var e = _dock.get_edit_store().events[index]
	if typeof(e) != TYPE_DICTIONARY:
		return
	_dock.set_selected_timeline_id_val(str(e.get("id", "")))
	if str(e.get("kind", "")) == "file":
		show_diff(str(e.get("old_content", "")), str(e.get("new_content", "")))
	else:
		show_diff("", "")


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
	_dock.apply_editor_decorations()
