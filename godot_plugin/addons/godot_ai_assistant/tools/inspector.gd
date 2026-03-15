@tool
extends RefCounted
class_name GodotAIInspector

## List @export variables for a script or node.

static func execute_get_export_vars(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var script_path: String = str(output.get("script_path", "")).strip_edges()
	var node_path: String = str(output.get("node_path", "")).strip_edges()
	var scene_path: String = str(output.get("scene_path", "")).strip_edges()
	var script: Script = null
	if not script_path.is_empty():
		script = load(script_path) as Script
	elif not scene_path.is_empty() and not node_path.is_empty():
		var editor_interface: EditorInterface = executor.editor_interface if executor else null
		if editor_interface:
			var root: Node = editor_interface.get_edited_scene_root()
			if root:
				var node: Node = root.get_node_or_null(node_path)
				if node and node.get_script():
					script = node.get_script()
	if not script:
		return {"success": false, "message": "Could not resolve script (provide script_path or scene_path+node_path)."}
	var props: Array = script.get_script_property_list()
	var exports: Array = []
	for p in props:
		var d: Dictionary = p
		if (d.get("usage", 0) as int) & 512:  # PROPERTY_USAGE_SCRIPT_VARIABLE
			exports.append({
				"name": d.get("name", ""),
				"type": d.get("type", TYPE_NIL),
				"hint": d.get("hint", 0),
			})
	return {
		"success": true,
		"message": "Found %d @export/property(ies)." % exports.size(),
		"exports": exports,
	}
