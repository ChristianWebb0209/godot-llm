@tool
extends RefCounted
class_name GodotAIChatContextMenu

## Controller: chat right-click menu actions (copy/export) + message index hit-testing.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func on_chat_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return
	_dock.set_context_menu_message_index(-1)
	if (
		_dock.chat_message_list != null
		and _dock.get_current_chat() >= 0
		and _dock.get_current_chat() < _dock.get_chats().size()
	):
		var list_pos: Vector2 = _dock.chat_message_list.get_local_mouse_position()
		for child in _dock.chat_message_list.get_children():
			if not child.has_meta("_ai_message_index"):
				continue
			var r := Rect2(child.position, child.size)
			if r.has_point(list_pos):
				_dock.set_context_menu_message_index(int(child.get_meta("_ai_message_index")))
				break
	var menu := _dock.get_chat_context_menu()
	if menu == null:
		return
	menu.clear()
	if _dock.get_context_menu_message_index() >= 0:
		var messages: Array = _dock.get_chats()[_dock.get_current_chat()].get("messages", [])
		if _dock.get_context_menu_message_index() < messages.size():
			var role: String = messages[_dock.get_context_menu_message_index()].get("role", "assistant")
			menu.add_item("Copy %s message" % role.capitalize(), 0)
	menu.add_item("Copy whole chat", 1)
	menu.add_item("Export chat", 2)
	menu.position = _dock.get_global_mouse_position()
	menu.popup()
	event.accept_event()


func on_menu_id_pressed(id: int) -> void:
	if id == 0:
		copy_message_at_index(_dock.get_context_menu_message_index())
	elif id == 1:
		copy_whole_chat()
	elif id == 2:
		var dlg := _dock.get_export_file_dialog()
		if dlg:
			dlg.current_file = "chat_export.txt"
			dlg.popup_centered()


func copy_message_at_index(msg_index: int) -> void:
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size() or msg_index < 0:
		return
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()].get("messages", [])
	if msg_index >= messages.size():
		return
	var msg: Dictionary = messages[msg_index]
	var role: String = msg.get("role", "assistant")
	var text: String = msg.get("text", "")
	var line: String = role.capitalize() + ":\n" + text
	DisplayServer.clipboard_set(line)
	_dock.set_status("Copied message to clipboard.")


func copy_whole_chat() -> void:
	var text_to_copy: String = ""
	if _dock.chat_message_list != null and _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		var lines: PackedStringArray = []
		for msg in _dock.get_chats()[_dock.get_current_chat()].get("messages", []):
			if msg.get("hidden", false):
				continue
			var role: String = msg.get("role", "assistant")
			var text: String = msg.get("text", "")
			lines.append(role.capitalize() + ":\n" + text)
		text_to_copy = "\n\n".join(lines)
	elif _dock.output_text_edit:
		text_to_copy = _dock.output_text_edit.get_parsed_text()
	if text_to_copy.is_empty():
		_dock.set_status("Nothing to copy.")
		return
	DisplayServer.clipboard_set(text_to_copy)
	_dock.set_status("Copied chat to clipboard.")


func export_chat_to_path(path: String) -> void:
	var text_to_export: String = ""
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		var lines: PackedStringArray = []
		for msg in _dock.get_chats()[_dock.get_current_chat()].get("messages", []):
			if msg.get("hidden", false):
				continue
			var role: String = msg.get("role", "assistant")
			var text: String = msg.get("text", "")
			lines.append(role.capitalize() + ":\n" + text)
		text_to_export = "\n\n".join(lines)
	if text_to_export.is_empty():
		_dock.set_status("Nothing to export.")
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text_to_export)
		f.close()
		_dock.set_status("Exported chat to %s" % path)
	else:
		_dock.set_status("Failed to export: %s" % path)

