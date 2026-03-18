@tool
extends EditorContextMenuPlugin
class_name GodotAIAddToContextMenuPlugin

## Adds "Add to context" at the top of script editor, FileSystem, and Scene tree context menus.
## One plugin instance per slot; each calls the dock's add_pinned_context_from_drag_data.

var _dock: GodotAIDock = null
var _editor_interface: EditorInterface = null
var _slot: int = -1

# Use EditorContextMenuPlugin's built-in CONTEXT_SLOT_* constants.


func _init(
	p_slot: int = -1,
	p_dock: GodotAIDock = null,
	p_editor_interface: EditorInterface = null
) -> void:
	_slot = p_slot
	_dock = p_dock
	_editor_interface = p_editor_interface


func set_dock(p_dock: GodotAIDock) -> void:
	_dock = p_dock


func set_editor_interface(p_editor_interface: EditorInterface) -> void:
	_editor_interface = p_editor_interface


func set_slot(p_slot: int) -> void:
	_slot = p_slot


func _popup_menu(paths: PackedStringArray) -> void:
	if _dock == null:
		return
	match _slot:
		CONTEXT_SLOT_SCRIPT_EDITOR_CODE:
			add_context_menu_item("Add to context", _on_script_code_add_to_context)
		CONTEXT_SLOT_FILESYSTEM:
			if paths.size() > 0:
				add_context_menu_item("Add to context", _on_filesystem_add_to_context)
		CONTEXT_SLOT_SCENE_TREE:
			if paths.size() > 0:
				add_context_menu_item("Add to context", _on_scene_tree_add_to_context)
		CONTEXT_SLOT_SCRIPT_EDITOR:
			add_context_menu_item("Add to context", _on_script_tab_add_to_context)
		_:
			pass


func _on_script_code_add_to_context(args: Array) -> void:
	if _dock == null or args.is_empty():
		return
	var code_edit = args[0]
	if code_edit == null:
		return
	# CodeEdit / TextEdit: get_selected_text()
	var text: String = ""
	if code_edit.has_method("get_selected_text"):
		text = code_edit.get_selected_text()
	if text.strip_edges().is_empty() and _editor_interface:
		# No selection: add current script file as context
		var script_editor = _editor_interface.get_script_editor()
		if script_editor and script_editor.has_method("get_current_script"):
			var script_res = script_editor.get_current_script()
			if script_res is Script and (script_res as Script).resource_path:
				var path_str: String = (script_res as Script).resource_path
				_dock.add_pinned_context_from_drag_data({"resource_path": path_str})
				return
		return
	var source_path: String = ""
	if _editor_interface:
		var script_editor = _editor_interface.get_script_editor()
		if script_editor and script_editor.has_method("get_current_script"):
			var script_res = script_editor.get_current_script()
			if script_res is Script and (script_res as Script).resource_path:
				source_path = (script_res as Script).resource_path
	_dock.add_pinned_context_from_drag_data({"selection_text": text, "source_path": source_path})


func _on_filesystem_add_to_context(args: Array) -> void:
	if _dock == null:
		return
	var paths: Array = []
	for a in args:
		if a is String:
			var p: String = (a as String).strip_edges()
			if not p.is_empty():
				if not p.begins_with("res://"):
					p = "res://" + p
				paths.append(p)
	if paths.is_empty():
		return
	_dock.add_pinned_context_from_drag_data({"files": paths})


func _on_scene_tree_add_to_context(args: Array) -> void:
	if _dock == null:
		return
	# args = list of selected Node objects (from engine)
	var node_list: Array = []
	var scene_path: String = ""
	if _editor_interface:
		var root = _editor_interface.get_edited_scene_root()
		if root:
			scene_path = root.scene_file_path
	for a in args:
		if a is Node:
			var n: Node = a as Node
			node_list.append({"path": str(n.get_path()), "name": n.name})
	if node_list.is_empty():
		return
	_dock.add_pinned_context_from_drag_data({"nodes": node_list, "scene": scene_path})


func _on_script_tab_add_to_context(args: Array) -> void:
	if _dock == null or args.is_empty():
		return
	var script_res = args[0]
	if script_res is Script and (script_res as Script).resource_path:
		var path_str: String = (script_res as Script).resource_path
		_dock.add_pinned_context_from_drag_data({"resource_path": path_str})
	elif script_res is Script:
		_dock.add_pinned_context_from_drag_data({"script": script_res})
