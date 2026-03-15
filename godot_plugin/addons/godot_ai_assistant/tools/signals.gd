@tool
extends RefCounted
class_name GodotAISignals

## List signals for a node type or script; connect a signal on a node.

static func execute_get_signals(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var node_type: String = str(output.get("node_type", "")).strip_edges()
	var script_path: String = str(output.get("script_path", "")).strip_edges()
	if node_type.is_empty() and script_path.is_empty():
		return {"success": false, "message": "node_type or script_path is required."}
	var list: Array = []
	if not node_type.is_empty():
		var signals_list: Array = ClassDB.class_get_signal_list(node_type)
		for s in signals_list:
			var sig: Dictionary = s
			var name_str: String = sig.get("name", "")
			var args_list: Array = sig.get("args", [])
			list.append({"name": name_str, "args": args_list})
	if not script_path.is_empty():
		var script: Script = load(script_path) as Script
		if script:
			var sigs: Array = script.get_script_signal_list()
			for s in sigs:
				list.append({"name": s.get("name", ""), "args": s.get("args", [])})
	return {
		"success": true,
		"message": "Found %d signal(s)." % list.size(),
		"signals": list,
	}


static func execute_connect_signal(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var scene_path: String = str(output.get("scene_path", "")).strip_edges()
	var node_path: String = str(output.get("node_path", "")).strip_edges()
	var signal_name: String = str(output.get("signal_name", "")).strip_edges()
	var callable_target: String = str(output.get("callable_target", "")).strip_edges()
	if scene_path.is_empty() or node_path.is_empty() or signal_name.is_empty():
		return {"success": false, "message": "scene_path, node_path, and signal_name are required."}
	var editor_interface: EditorInterface = executor.editor_interface if executor else null
	if not editor_interface:
		return {"success": false, "message": "Editor not available."}
	var root: Node = editor_interface.get_edited_scene_root()
	if not root:
		return {"success": false, "message": "No scene open. Open the scene first."}
	var node: Node = root.get_node_or_null(node_path)
	if not node:
		return {"success": false, "message": "Node not found: %s" % node_path}
	if not node.has_signal(signal_name):
		return {"success": false, "message": "Signal '%s' not found on node." % signal_name}
	if callable_target.is_empty():
		return {"success": false, "message": "callable_target is required (e.g. ../Player/on_clicked)."}
	var parts: PackedStringArray = callable_target.split("/")
	var method_name: String = parts[parts.size() - 1] if parts.size() > 0 else ""
	var path_to_node: String = ""
	if parts.size() > 1:
		path_to_node = "/".join(parts.slice(0, parts.size() - 1))
	var target_node: Node = null
	if path_to_node.is_empty():
		target_node = node.get_node_or_null(callable_target)
		if not target_node:
			target_node = node  # same node, callable_target is method name only
	else:
		target_node = node.get_node_or_null(path_to_node)
	if not target_node:
		return {"success": false, "message": "Target node not found: %s" % callable_target}
	if not target_node.has_method(method_name):
		return {"success": false, "message": "Target has no method: %s" % method_name}
	var err: Error = node.connect(signal_name, Callable(target_node, method_name))
	if err != OK:
		return {"success": false, "message": "Connect failed: error %d" % err}
	return {
		"success": true,
		"message": "Connected %s.%s to %s" % [node_path, signal_name, callable_target],
	}
