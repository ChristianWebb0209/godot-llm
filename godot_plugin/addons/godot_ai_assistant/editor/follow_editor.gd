@tool
extends RefCounted
class_name GodotAIFollowEditor

## Centralized follow behavior: switch main screen (2D, 3D, Script) and open resources.
## Used by file and node tools when follow_agent is enabled.
## Main screen names match Godot editor tab names: "2D", "3D", "Script".


## Switch the main editor tab to 2D.
static func switch_to_2d(editor_interface: EditorInterface) -> void:
	if editor_interface:
		editor_interface.set_main_screen_editor("2D")


## Switch the main editor tab to 3D.
static func switch_to_3d(editor_interface: EditorInterface) -> void:
	if editor_interface:
		editor_interface.set_main_screen_editor("3D")


## Switch the main editor tab to Script.
static func switch_to_script(editor_interface: EditorInterface) -> void:
	if editor_interface:
		editor_interface.set_main_screen_editor("Script")


## Open the script in the script editor and switch main screen to Script.
## path can be res:// or project path. Returns true if a script was opened.
static func open_script_and_switch(editor_interface: EditorInterface, path: String) -> bool:
	if editor_interface == null or path.is_empty():
		return false
	var p := path.replace("\\", "/").strip_edges()
	if not p.begins_with("res://"):
		p = "res://" + p
	var res: Resource = load(p) as Resource
	if res == null:
		return false
	if res is Script:
		editor_interface.set_main_screen_editor("Script")
		editor_interface.edit_script(res as Script, -1, 0, true)
		return true
	return false


## Open the scene at scene_path. Caller should await process_frame then call switch_main_screen_for_scene().
static func open_scene_from_path(editor_interface: EditorInterface, scene_path: String) -> void:
	if editor_interface and not scene_path.is_empty():
		editor_interface.open_scene_from_path(scene_path)


## After a scene is open, switch main screen to 2D or 3D based on edited scene root.
static func switch_main_screen_for_scene(editor_interface: EditorInterface) -> void:
	if editor_interface == null:
		return
	var root: Node = editor_interface.get_edited_scene_root()
	if root == null:
		return
	var cls := root.get_class()
	if ClassDB.is_parent_class(cls, "Node3D"):
		editor_interface.set_main_screen_editor("3D")
	else:
		# Node2D, Control, Node, etc.
		editor_interface.set_main_screen_editor("2D")


## Schedule a switch to 2D/3D next frame (use when scene was just opened and we can't await).
static func deferred_switch_main_screen_for_scene(editor_interface: EditorInterface) -> void:
	if editor_interface == null:
		return
	var base: Control = editor_interface.get_base_control()
	if base == null:
		return
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.1
	var ei := editor_interface
	timer.timeout.connect(func() -> void:
		GodotAIFollowEditor.switch_main_screen_for_scene(ei)
		if timer.is_inside_tree():
			timer.queue_free()
	)
	base.add_child(timer)
	timer.start()


## Return "2d" or "3d" for the given node type (class name).
static func dimension_for_node_type(node_type: String) -> String:
	var t := node_type.strip_edges()
	if ClassDB.is_parent_class(t, "Node3D"):
		return "3d"
	return "2d"


## Focus editor on a changed file: FileSystem dock (bottom left) and Scene tree (top left) open/select the item.
## file_path can be res:// or absolute project path.
static func focus_editor_on_file(editor_interface: EditorInterface, file_path: String) -> void:
	if editor_interface == null or file_path.is_empty():
		return
	var res_path := GodotAIEditStore.normalize_for_display_match(file_path)
	if res_path.is_empty():
		return
	# FileSystem dock: open directories and select this file
	var fs_dock = editor_interface.get_file_system_dock()
	if fs_dock != null and fs_dock.has_method("navigate_to_path"):
		fs_dock.navigate_to_path(res_path)
	# Scene tree: if this is a scene file, open it and select the root so the scene tree shows/selects it
	var ext := res_path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		editor_interface.open_scene_from_path(res_path)
		var root: Node = editor_interface.get_edited_scene_root()
		if root != null:
			var sel = editor_interface.get_selection()
			if sel != null:
				sel.clear()
				sel.add_node(root)
			editor_interface.edit_node(root)

