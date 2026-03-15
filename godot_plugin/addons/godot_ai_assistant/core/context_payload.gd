@tool
extends RefCounted
class_name GodotAIContextPayload

## Builds the "context" dict for RAG/query (engine, script, scene, project_root, optional lint_output, conversation_history).
## conversation_messages: optional Array of {"role": "user"|"assistant", "text": "..."} (last N turns for continuity).

static func build(
	editor_interface: EditorInterface,
	override_file_path: String = "",
	override_file_text: String = "",
	lint_output: String = "",
	conversation_messages: Array = []
) -> Dictionary:
	var active_script_path := ""
	var active_script_text := ""
	var active_scene_path := ""
	var scene_root_class := ""
	var scene_dimension := ""  # "2d" or "3d" so the LLM uses correct node types
	var selected_node_type := ""
	var selected_node_base_type := ""
	var project_root_abs := ProjectSettings.globalize_path("res://")
	var scene_tree_text := ""
	var open_scripts_preview: Array = []  # Top 5 open tabs, first 24 lines each

	if not override_file_path.is_empty():
		active_script_path = override_file_path
		active_script_text = override_file_text if not override_file_text.is_empty() else _read_file_res(
			override_file_path
		)
	elif editor_interface:
		var scene_root := editor_interface.get_edited_scene_root()
		if scene_root:
			active_scene_path = scene_root.scene_file_path
			scene_root_class = scene_root.get_class()
			if ClassDB.is_parent_class(scene_root_class, "Node3D"):
				scene_dimension = "3d"
			elif ClassDB.is_parent_class(scene_root_class, "Node2D"):
				scene_dimension = "2d"
			else:
				scene_dimension = "2d"  # Node, Control, etc. — treat as 2d for safety
		var scene_root_for_tree := editor_interface.get_edited_scene_root()
		if scene_root_for_tree:
			scene_tree_text = _build_scene_tree_text(scene_root_for_tree)
		# Selected node type (for scene/node context) — always from selection.
		var selected_script: Script = null
		var selection := editor_interface.get_selection() if editor_interface else null
		if selection:
			var nodes := selection.get_selected_nodes()
			if nodes and nodes.size() > 0:
				var n: Node = nodes[0]
				if n:
					selected_node_type = n.get_class()
					if not selected_node_type.is_empty() and ClassDB.class_exists(selected_node_type):
						selected_node_base_type = ClassDB.get_parent_class(selected_node_type)
					if n.get_script() is Script:
						selected_script = n.get_script()
		if selected_script == null and scene_root and scene_root.get_script() is Script:
			selected_script = scene_root.get_script()
		# Prefer the script currently open in the Script Editor tab (what the user is looking at).
		var script_editor = editor_interface.get_script_editor() if editor_interface else null
		if script_editor and script_editor.has_method("get_current_script"):
			var current_script: Script = script_editor.get_current_script()
			if current_script is Script and current_script.resource_path:
				active_script_path = current_script.resource_path
				if "source_code" in current_script:
					active_script_text = current_script.source_code
				elif active_script_path:
					active_script_text = _read_file_res(active_script_path)
		# Fallback: script attached to selected node or scene root (when no script tab is active).
		if active_script_path.is_empty() and selected_script:
			active_script_path = selected_script.resource_path
			if "source_code" in selected_script:
				active_script_text = selected_script.source_code
		# First ~24 lines of top 5 open script tabs (so the model sees what files the user has open).
		if script_editor and script_editor.has_method("get_open_scripts"):
			var open_list: Array = script_editor.get_open_scripts()
			const MAX_OPEN_PREVIEW := 5
			const PREVIEW_LINES := 24
			for script_idx in range(mini(open_list.size(), MAX_OPEN_PREVIEW)):
				var scr: Script = open_list[script_idx]
				if scr is Script and scr.resource_path:
					var path_str: String = scr.resource_path
					var full_text: String = ""
					if "source_code" in scr:
						full_text = scr.source_code
					elif path_str:
						full_text = _read_file_res(path_str)
					var lines: PackedStringArray = full_text.split("\n")
					var head_parts: Array[String] = []
					for line_idx in range(mini(lines.size(), PREVIEW_LINES)):
						head_parts.append(lines[line_idx])
					var head: String = "\n".join(head_parts)
					if full_text.length() > head.length():
						head += "\n..."
					open_scripts_preview.append({"path": path_str, "preview": head})

	var extra: Dictionary = {
		"active_file_text": active_script_text,
		"active_scene_path": active_scene_path,
		"project_root_abs": project_root_abs,
	}
	if not scene_root_class.is_empty():
		extra["scene_root_class"] = scene_root_class
	if not scene_dimension.is_empty():
		extra["scene_dimension"] = scene_dimension
	if not selected_node_base_type.is_empty():
		extra["selected_node_base_type"] = selected_node_base_type
	if not lint_output.is_empty():
		extra["lint_output"] = lint_output
	if not scene_tree_text.is_empty():
		extra["scene_tree"] = scene_tree_text
	if conversation_messages.size() > 0:
		extra["conversation_history"] = _format_conversation_for_backend(conversation_messages)
	if open_scripts_preview.size() > 0:
		extra["open_scripts_preview"] = open_scripts_preview

	return {
		"engine_version": Engine.get_version_info().get("string"),
		"language": "gdscript",
		"selected_node_type": selected_node_type,
		"current_script": active_script_path,
		"extra": extra,
	}


static func _build_scene_tree_text(root: Node) -> String:
	if root == null:
		return ""
	var lines: PackedStringArray = []
	_build_scene_tree_lines(root, 0, lines)
	var out: Array[String] = []
	for i in lines.size():
		out.append(lines[i])
	return "\n".join(out)


static func _build_scene_tree_lines(node: Node, depth: int, lines: PackedStringArray) -> void:
	if node == null:
		return
	var indent := ""
	for i in depth:
		indent += "  "
	var node_class := node.get_class()
	var line := indent + node.name + " (" + node_class + ")"
	lines.append(line)
	for child in node.get_children():
		_build_scene_tree_lines(child, depth + 1, lines)


static func read_file_res(path: String) -> String:
	return _read_file_res(path)


static func _read_file_res(path: String) -> String:
	if path.is_empty():
		return ""
	var p := path
	if p.begins_with("res://"):
		p = p.substr(6)
	var abs_path := ProjectSettings.globalize_path("res://").path_join(p)
	if not FileAccess.file_exists(abs_path):
		return ""
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


static func _format_conversation_for_backend(messages: Array) -> Array:
	const MAX_MESSAGES := 20
	var out: Array = []
	var start := maxi(0, messages.size() - MAX_MESSAGES)
	for i in range(start, messages.size()):
		var m: Variant = messages[i]
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = m
		var role: String = (d.get("role", "") as String).strip_edges()
		var text: String = (d.get("text", d.get("content", "")) as String).strip_edges()
		if role.is_empty():
			continue
		out.append({"role": role, "content": text})
	return out
