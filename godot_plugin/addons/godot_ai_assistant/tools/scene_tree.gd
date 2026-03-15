@tool
extends RefCounted
class_name GodotAISceneTree

## Get scene tree structure (node names, types, hierarchy) for current open scene or a .tscn path.

static func _node_to_dict(node: Node, base_path: String) -> Dictionary:
	var path_str: String = base_path + "/" + node.name if base_path else node.name
	var children: Array = []
	for i in range(node.get_child_count()):
		var c: Node = node.get_child(i)
		children.append(_node_to_dict(c, path_str))
	return {
		"name": node.name,
		"type": node.get_class(),
		"path": path_str,
		"children": children,
	}


static func execute_get_node_tree(
	executor: GodotAIEditorToolExecutor, output: Dictionary
) -> Dictionary:
	var scene_path: String = str(output.get("scene_path", "")).strip_edges()
	var editor_interface: EditorInterface = executor.editor_interface if executor else null
	if not editor_interface:
		return {"success": false, "message": "Editor not available."}
	var root: Node = null
	if scene_path.is_empty():
		var scene_root: Node = editor_interface.get_edited_scene_root()
		if scene_root:
			root = scene_root
		else:
			return {
			"success": false,
			"message": "No scene open. Specify scene_path (e.g. res://main.tscn) or open a scene.",
		}
	else:
		if not scene_path.begins_with("res://"):
			scene_path = "res://" + scene_path
		var packed: Resource = load(scene_path) as PackedScene
		if not packed:
			return {"success": false, "message": "Failed to load scene: %s" % scene_path}
		root = packed.instantiate()
		if not root:
			return {"success": false, "message": "Failed to instantiate: %s" % scene_path}
	var tree_dict: Dictionary = _node_to_dict(root, "")
	if root != editor_interface.get_edited_scene_root():
		root.queue_free()
	return {
		"success": true,
		"message": "Scene tree for %s" % (scene_path if scene_path else "current scene"),
		"scene_path": scene_path if scene_path else "(current)",
		"tree": tree_dict,
	}
