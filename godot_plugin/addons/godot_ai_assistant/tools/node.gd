@tool
extends RefCounted
class_name GodotAINode

## Scene/node operations: create_node, set_node_property, modify_attribute. Async-capable.

var executor: GodotAIEditorToolExecutor

func _init(p_executor: GodotAIEditorToolExecutor) -> void:
	executor = p_executor


func execute_create_node_sync(_output: Dictionary) -> Dictionary:
	return {"success": false, "message": "create_node requires async; use execute_async from the dock."}


func execute_set_node_property_sync(_output: Dictionary) -> Dictionary:
	return {"success": false, "message": "set_node_property requires async; use execute_async from the dock."}


## When no scene is open, create res://scenes/ai_generated.tscn with a root Node2D so create_node can attach to something.
static func _ensure_new_scene_for_node(exec: GodotAIEditorToolExecutor) -> String:
	const default_path := "res://scenes/ai_generated.tscn"
	var abs_dir := exec.project_path_to_absolute("res://scenes")
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var abs_file := exec.project_path_to_absolute(default_path)
	# Minimal Godot 4 .tscn: one root Node2D
	var content := "[gd_scene load_steps=1 format=3]\n\n[node name=\"Root\" type=\"Node2D\"]\n"
	var f := FileAccess.open(abs_file, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(content)
	f.close()
	return default_path


func execute_create_node(output: Dictionary) -> Dictionary:
	if executor.editor_interface == null:
		return {"success": false, "message": "Editor not available."}
	var prev_root: Node = executor.editor_interface.get_edited_scene_root()
	var prev_scene_path := ""
	if prev_root and prev_root.scene_file_path != "":
		prev_scene_path = prev_root.scene_file_path
	var scene_path_raw: String = str(output.get("scene_path", "")).strip_edges()
	if scene_path_raw.is_empty() or scene_path_raw.to_lower() == "current":
		scene_path_raw = prev_scene_path
	var scene_path: String = executor.normalize_res_path(scene_path_raw)
	var parent_path: String = str(output.get("parent_path", "/root")).strip_edges()
	var node_type: String = str(output.get("node_type", "Node")).strip_edges()
	var node_name: String = str(output.get("node_name", "")).strip_edges()
	if node_type.is_empty():
		return {"success": false, "message": "node_type is required"}
	# If no scene is open (current), create a new scene with a root so we always have somewhere to attach the node.
	if scene_path.is_empty():
		scene_path = _ensure_new_scene_for_node(executor)
		if scene_path.is_empty():
			return {"success": false, "message": "No scene open and could not create one. Open a scene in the editor or create res://scenes/ first."}
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return {"success": false, "message": "Scene not found: %s (use res:// path)" % scene_path}
	executor.editor_interface.open_scene_from_path(scene_path)
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	var root: Node = executor.editor_interface.get_edited_scene_root()
	if root == null:
		return {"success": false, "message": "Scene opened but root not ready. Try again."}
	var parent: Node = root
	if not parent_path.is_empty() and parent_path != "/" and parent_path != "/root":
		var path_trimmed := parent_path.trim_prefix("/root/").trim_prefix("/")
		if not path_trimmed.is_empty():
			parent = root.get_node_or_null(path_trimmed)
			if parent == null:
				parent = root.get_node_or_null(parent_path)
			if parent == null:
				return {"success": false, "message": "Parent not found: %s (e.g. /root or /root/Main)" % parent_path}
	var new_node: Node = ClassDB.instantiate(node_type)
	if new_node == null:
		var hint := " Use built-in: Node, Node2D, Control, Button, Label, CharacterBody2D, Sprite2D (not 'Component')."
		return {"success": false, "message": "Invalid node type: %s.%s" % [node_type, hint]}
	if not node_name.is_empty():
		new_node.name = node_name
	parent.add_child(new_node)
	new_node.owner = root
	executor.editor_interface.save_scene()
	var node_path_str := new_node.name
	if parent != root:
		var p := str(parent.get_path()).trim_prefix("/root/").trim_prefix("/")
		node_path_str = p.path_join(new_node.name)
	var msg := "Added %s to %s" % [node_type, scene_path]
	if not executor.follow_agent and prev_scene_path != "" and prev_scene_path != scene_path:
		executor.editor_interface.open_scene_from_path(prev_scene_path)
	return {
		"success": true,
		"message": msg,
		"edit_record": {
			"action_type": "create_node",
			"scene_path": scene_path,
			"node_path": node_path_str,
			"node_type": node_type,
			"summary": msg,
		}
	}


func execute_set_node_property(output: Dictionary) -> Dictionary:
	if executor.editor_interface == null:
		return {"success": false, "message": "Editor not available."}
	var prev_root: Node = executor.editor_interface.get_edited_scene_root()
	var prev_scene_path := ""
	if prev_root and prev_root.scene_file_path != "":
		prev_scene_path = prev_root.scene_file_path
	var scene_path_raw: String = str(output.get("scene_path", "")).strip_edges()
	if scene_path_raw.is_empty() or scene_path_raw.to_lower() == "current":
		scene_path_raw = prev_scene_path
	var scene_path: String = executor.normalize_res_path(scene_path_raw)
	var node_path: String = str(output.get("node_path", ""))
	var property_name: String = str(output.get("property_name", ""))
	var value = output.get("value")
	if scene_path.is_empty() or node_path.is_empty() or property_name.is_empty():
		return {"success": false, "message": "scene_path, node_path, property_name required (or have a scene open for 'current')"}
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return {"success": false, "message": "Scene not found: %s (use res:// path)" % scene_path}
	executor.editor_interface.open_scene_from_path(scene_path)
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	var root: Node = executor.editor_interface.get_edited_scene_root()
	if root == null:
		return {"success": false, "message": "No scene root."}
	var target: Node = root.get_node_or_null(node_path)
	if target == null:
		var path_trimmed := node_path.trim_prefix("/root/").trim_prefix("/")
		target = root.get_node_or_null(path_trimmed)
	if target == null:
		return {"success": false, "message": "Node not found: %s" % node_path}
	var parsed := _parse_property_value_for(target, property_name, value)
	if parsed == null and value != null:
		return {"success": false, "message": "Could not parse value for property"}
	if not _property_writable(target, property_name):
		return {"success": false, "message": "Property not found or read-only: %s" % property_name}
	target.set(property_name, parsed)
	executor.editor_interface.save_scene()
	var normalized := node_path.trim_prefix("/root/").trim_prefix("/")
	var msg := "Set %s.%s" % [normalized, property_name]
	if not executor.follow_agent and prev_scene_path != "" and prev_scene_path != scene_path:
		executor.editor_interface.open_scene_from_path(prev_scene_path)
	return {
		"success": true,
		"message": msg,
		"edit_record": {
			"action_type": "set_node_property",
			"scene_path": scene_path,
			"node_path": normalized,
			"property_name": property_name,
			"summary": msg,
		}
	}


func execute_modify_attribute(output: Dictionary) -> Dictionary:
	var tt := str(output.get("target_type", "")).strip_edges().to_lower()
	if tt == "import":
		var payload := {"path": output.get("path"), "key": output.get("attribute"), "value": output.get("value")}
		return GodotAIImport.execute_set_import_option(executor, payload)
	if tt == "node":
		var payload := {
			"scene_path": output.get("scene_path"),
			"node_path": output.get("node_path"),
			"property_name": output.get("attribute"),
			"value": output.get("value"),
		}
		return execute_set_node_property_sync(payload)
	return {"success": false, "message": "modify_attribute: target_type must be node or import"}


func execute_modify_attribute_async(output: Dictionary):
	var tt := str(output.get("target_type", "")).strip_edges().to_lower()
	if tt == "import":
		var payload := {"path": output.get("path"), "key": output.get("attribute"), "value": output.get("value")}
		return GodotAIImport.execute_set_import_option(executor, payload)
	if tt == "node":
		var payload := {
			"scene_path": output.get("scene_path"),
			"node_path": output.get("node_path"),
			"property_name": output.get("attribute"),
			"value": output.get("value"),
		}
		return await execute_set_node_property(payload)
	return {"success": false, "message": "modify_attribute: target_type must be node or import"}


func _property_writable(obj: Object, prop: String) -> bool:
	for d in obj.get_property_list():
		if d.get("name", "") == prop:
			var usage: int = d.get("usage", 0) as int
			return (usage & PROPERTY_USAGE_READ_ONLY) == 0
	return false


func _get_property_type(obj: Object, prop: String) -> int:
	for d in obj.get_property_list():
		if d.get("name", "") == prop:
			return d.get("type", TYPE_NIL) as int
	return TYPE_NIL


func _parse_property_value_for(obj: Object, prop_name: String, value) -> Variant:
	var prop_type: int = _get_property_type(obj, prop_name)
	var str_val: String = str(value) if value != null else ""
	# Type-aware parsing for Godot 4; fallback to generic parser for unknown types.
	match prop_type:
		TYPE_NODE_PATH:
			return NodePath(str_val) if not str_val.is_empty() else NodePath()
		TYPE_STRING_NAME:
			return StringName(str_val)
		TYPE_OBJECT:
			if value is Object:
				return value
			if str_val.begins_with("res://") and ResourceLoader.exists(str_val):
				return load(str_val) as Resource
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_RECT2, TYPE_AABB, TYPE_PLANE:
			# Let generic parser try; otherwise leave to engine if possible.
			pass
	var parsed := _parse_property_value(value)
	if parsed != null:
		return parsed
	if value != null and prop_type != TYPE_NIL:
		return value
	return null


func _parse_property_value(value) -> Variant:
	if value == null:
		return null
	if value is int or value is float or value is bool or value is String:
		return value
	if value is Array:
		var arr: Array = value
		if arr.size() == 2:
			return Vector2(float(arr[0]), float(arr[1]))
		if arr.size() == 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
		if arr.size() == 4:
			return Color(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))
	if value is Dictionary:
		var d: Dictionary = value
		if d.has("x") and d.has("y") and not d.has("z"):
			return Vector2(float(d.x), float(d.y))
		if d.has("x") and d.has("y") and d.has("z"):
			return Vector3(float(d.x), float(d.y), float(d.z))
	return value
