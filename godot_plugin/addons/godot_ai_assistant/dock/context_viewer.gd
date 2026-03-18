@tool
extends RefCounted
class_name GodotAIContextViewer

## Controller: Context Viewer panel toggle + rendering of per-chat context blocks.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func toggle() -> void:
	if not _dock.io_container or not _dock.context_viewer_panel:
		return
	var show_panel: bool = not _dock.context_viewer_panel.visible
	_dock.context_viewer_panel.visible = show_panel
	_dock.io_container.visible = not show_panel
	if show_panel:
		refresh()


func refresh() -> void:
	if not _dock.context_viewer_list or not _dock.context_viewer_empty_label:
		return
	# Clear existing block UIs
	for child in _dock.context_viewer_list.get_children():
		child.queue_free()
	var usage: Dictionary = {}
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		usage = _dock.get_chats()[_dock.get_current_chat()].get("context_usage", {})
	var view_arr: Array = usage.get("context_view", [])
	if view_arr.is_empty():
		_dock.context_viewer_empty_label.visible = true
		_dock.context_viewer_list.get_parent().visible = false
		return
	_dock.context_viewer_empty_label.visible = false
	_dock.context_viewer_list.get_parent().visible = true
	var exclude_keys: Array = []
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		exclude_keys = _dock.get_chats()[_dock.get_current_chat()].get("exclude_context_keys", [])
	for blk in view_arr:
		if typeof(blk) != TYPE_DICTIONARY:
			continue
		var key: String = str(blk.get("key", ""))
		var title: String = str(blk.get("title", "Context block"))
		var est_tok: int = int(blk.get("estimated_tokens", 0))
		var included: bool = blk.get("included", true)
		var mode: String = str(blk.get("mode", "as_is"))
		var preview: String = str(blk.get("content_preview", ""))
		var user_excluded: bool = key in exclude_keys

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 4)
		var header_row := HBoxContainer.new()
		var header := Label.new()
		var badge: String
		if not included:
			badge = "Dropped"
		elif user_excluded:
			badge = "Excluded by you"
		else:
			badge = "Included"
		header.text = "%s  |  %d tokens  |  %s  |  %s" % [title, est_tok, badge, mode]
		if not included:
			header.add_theme_color_override("font_color", Color(0.6, 0.4, 0.4))
		elif user_excluded:
			header.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		else:
			header.add_theme_color_override("font_color", Color(0.4, 0.6, 0.4))
		header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header_row.add_child(header)
		var exclude_btn := Button.new()
		exclude_btn.text = "Don't include next time" if not user_excluded else "Include again"
		exclude_btn.pressed.connect(toggle_exclude.bind(key))
		header_row.add_child(exclude_btn)
		box.add_child(header_row)
		var body := TextEdit.new()
		body.editable = false
		body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		body.text = preview
		body.custom_minimum_size.y = 120
		body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		box.add_child(body)
		_dock.context_viewer_list.add_child(box)

	# Decision log at the bottom
	var log_arr: Array = usage.get("context_decision_log", [])
	if not log_arr.is_empty():
		var sep := HSeparator.new()
		_dock.context_viewer_list.add_child(sep)
		var log_title := Label.new()
		log_title.text = "Context decisions"
		log_title.add_theme_font_size_override("font_size", 14)
		_dock.context_viewer_list.add_child(log_title)
		var log_text := "\n".join(log_arr)
		var log_body := TextEdit.new()
		log_body.editable = false
		log_body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		log_body.text = log_text
		log_body.custom_minimum_size.y = 80
		log_body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		_dock.context_viewer_list.add_child(log_body)


func toggle_exclude(block_key: String) -> void:
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return
	var chat: Dictionary = _dock.get_chats()[_dock.get_current_chat()]
	if not chat.has("exclude_context_keys"):
		chat["exclude_context_keys"] = []
	var arr: Array = chat["exclude_context_keys"]
	var idx := arr.find(block_key)
	if idx >= 0:
		arr.remove_at(idx)
	else:
		arr.append(block_key)
	refresh()

