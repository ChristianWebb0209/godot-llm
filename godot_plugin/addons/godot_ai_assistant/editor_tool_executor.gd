@tool
extends RefCounted
class_name GodotAIEditorToolExecutor

## Executes editor tool payloads returned by the RAG backend (create_file, write_file, create_node, etc.).
## Requires EditorInterface to be set; only runs when running in the editor.

var editor_interface: EditorInterface = null
var follow_agent: bool = true


func _init(p_editor_interface: EditorInterface = null) -> void:
	editor_interface = p_editor_interface


func execute(output: Dictionary) -> Dictionary:
	if not output.get("execute_on_client", false):
		return {"success": false, "message": "Not a client action."}
	var action: String = output.get("action", "")
	match action:
		"read_file":
			return _execute_read_file(output)
		"list_directory":
			return _execute_list_directory(output)
		"search_files":
			return _execute_search_files(output)
		"delete_file":
			return _execute_delete_file(output)
		"create_file":
			return _execute_create_file(output)
		"write_file":
			return _execute_write_file(output)
		"apply_patch":
			return _execute_apply_patch(output)
		"create_script":
			return _execute_create_script(output)
		"create_node":
			return _execute_create_node_sync(output)
		"set_node_property":
			return _execute_set_node_property_sync(output)
		_:
			return {"success": false, "message": "Unknown action: %s" % action}


## Call from dock when you can await (for create_node/set_node_property).
func execute_async(output: Dictionary) -> Dictionary:
	if not output.get("execute_on_client", false):
		return {"success": false, "message": "Not a client action."}
	var action: String = output.get("action", "")
	match action:
		"read_file":
			return _execute_read_file(output)
		"list_directory":
			return _execute_list_directory(output)
		"search_files":
			return _execute_search_files(output)
		"delete_file":
			return _execute_delete_file(output)
		"create_file":
			return _execute_create_file(output)
		"write_file":
			return _execute_write_file(output)
		"apply_patch":
			return _execute_apply_patch(output)
		"create_script":
			return _execute_create_script(output)
		"create_node":
			return await _execute_create_node(output)
		"set_node_property":
			return await _execute_set_node_property(output)
		_:
			return {"success": false, "message": "Unknown action: %s" % action}


## Build a preview record for file-based edits without applying them.
## Returns { ok: bool, message?: String, change?: Dictionary }
func preview_file_change(output: Dictionary) -> Dictionary:
	if not output.get("execute_on_client", false):
		return {"ok": false, "message": "Not a client action."}
	var action: String = output.get("action", "")
	match action:
		"create_file":
			return _preview_create_file(output)
		"write_file":
			return _preview_write_file(output)
		"apply_patch":
			return _preview_apply_patch(output)
		"create_script":
			return _preview_create_script(output)
		"delete_file":
			return _preview_delete_file(output)
		_:
			return {"ok": false, "message": "Not a file edit action: %s" % action}


func set_follow_agent(enabled: bool) -> void:
	follow_agent = enabled


func _project_path_to_absolute(res_path: String) -> String:
	if res_path.begins_with("res://"):
		return ProjectSettings.globalize_path(res_path)
	return res_path


func _execute_create_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	var overwrite: bool = output.get("overwrite", false)
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	var old_content := ""
	if FileAccess.file_exists(abs_path):
		var old_f := FileAccess.open(abs_path, FileAccess.READ)
		if old_f != null:
			old_content = old_f.get_as_text()
			old_f.close()
	if FileAccess.file_exists(abs_path) and not overwrite:
		return {"success": false, "message": "File already exists and overwrite is false: %s" % path}
	var dir := path.get_base_dir()
	if not dir.is_empty():
		var abs_dir := _project_path_to_absolute(dir)
		DirAccess.make_dir_recursive_absolute(abs_dir)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(content)
	f.close()
	# Optionally open the created resource in the editor when following.
	if editor_interface and follow_agent:
		var res := load(path)
		if res:
			editor_interface.edit_resource(res)
	return {
		"success": true,
		"message": "Created: %s" % path,
		"edit_record": {
			"file_path": path,
			"change_type": "create",
			"old_content": old_content,
			"new_content": content,
		}
	}


func _execute_write_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	var old_content := ""
	if FileAccess.file_exists(abs_path):
		var old_f := FileAccess.open(abs_path, FileAccess.READ)
		if old_f != null:
			old_content = old_f.get_as_text()
			old_f.close()
	var dir := path.get_base_dir()
	if not dir.is_empty():
		var abs_dir := _project_path_to_absolute(dir)
		DirAccess.make_dir_recursive_absolute(abs_dir)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(content)
	f.close()
	if editor_interface and follow_agent:
		var res := load(path)
		if res:
			editor_interface.edit_resource(res)
	return {
		"success": true,
		"message": "Wrote: %s" % path,
		"edit_record": {
			"file_path": path,
			"change_type": "modify",
			"old_content": old_content,
			"new_content": content,
		}
	}


func _execute_apply_patch(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var old_string: String = output.get("old_string", "")
	var new_string: String = output.get("new_string", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "File not found: %s" % path}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return {"success": false, "message": "Failed to open for read: %s" % path}
	var old_content: String = f.get_as_text()
	f.close()
	if old_string not in old_content:
		return {"success": false, "message": "old_string not found in file"}
	var new_content: String = old_content.replace(old_string, new_string)
	f = FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(new_content)
	f.close()
	if editor_interface and follow_agent:
		var res := load(path)
		if res:
			editor_interface.edit_resource(res)
	return {
		"success": true,
		"message": "Patched: %s" % path,
		"edit_record": {
			"file_path": path,
			"change_type": "modify",
			"old_content": old_content,
			"new_content": new_content,
		}
	}


func _execute_create_script(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var language: String = output.get("language", "gdscript")
	var extends_class: String = output.get("extends_class", "Node")
	var initial_content: String = output.get("initial_content", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var content: String
	if language == "csharp":
		content = "using Godot;\n\npublic partial class %s : %s\n{\n%s\n}\n" % [
			path.get_file().get_basename().replace(" ", ""),
			extends_class,
			initial_content
		]
	else:
		content = "extends %s\n\n%s" % [extends_class, initial_content]
	return _execute_write_file({"path": path, "content": content})


func _read_text_file_abs(abs_path: String) -> String:
	if not FileAccess.file_exists(abs_path):
		return ""
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _execute_read_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "File not found: %s" % path}
	var content := _read_text_file_abs(abs_path)
	var size := content.length()
	return {
		"success": true,
		"message": "Read: %s (%d chars)" % [path, size],
		"path": path,
		"content": content,
	}


func _execute_delete_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "File not found: %s" % path}
	var old_content := _read_text_file_abs(abs_path)
	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		return {"success": false, "message": "Failed to delete: %s (err=%d)" % [path, int(err)]}
	return {
		"success": true,
		"message": "Deleted: %s" % path,
		"edit_record": {
			"file_path": path,
			"change_type": "delete",
			"old_content": old_content,
			"new_content": "",
		}
	}


func _preview_delete_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "message": "File not found: %s" % path}
	var old_content := _read_text_file_abs(abs_path)
	return {
		"ok": true,
		"change": {
			"file_path": path,
			"change_type": "delete",
			"old_content": old_content,
			"new_content": "",
			"summary": "delete %s" % path,
			"apply_action": "delete_file",
		}
	}


func _execute_list_directory(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "res://")
	var recursive: bool = output.get("recursive", false)
	var max_entries: int = int(output.get("max_entries", 250))
	var max_depth: int = int(output.get("max_depth", 6))
	if path.is_empty():
		path = "res://"
	if max_entries < 1:
		max_entries = 1
	if max_entries > 2000:
		max_entries = 2000
	if max_depth < 0:
		max_depth = 0
	if max_depth > 20:
		max_depth = 20
	var results: Array = []
	var root_abs := _project_path_to_absolute(path)
	var stack: Array = [{"abs": root_abs, "res": path, "depth": 0}]
	while not stack.is_empty() and results.size() < max_entries:
		var cur: Dictionary = stack.pop_back()
		var dir_abs: String = str(cur.get("abs", ""))
		var dir_res: String = str(cur.get("res", ""))
		var depth: int = int(cur.get("depth", 0))
		var da := DirAccess.open(dir_abs)
		if da == null:
			continue
		da.list_dir_begin()
		while results.size() < max_entries:
			var name := da.get_next()
			if name.is_empty():
				break
			if name == "." or name == "..":
				continue
			var child_abs := dir_abs.path_join(name)
			var child_res := dir_res.trim_suffix("/").path_join(name)
			var is_dir := da.current_is_dir()
			results.append({"path": child_res, "is_dir": is_dir})
			if recursive and is_dir and depth < max_depth:
				stack.append({"abs": child_abs, "res": child_res, "depth": depth + 1})
		da.list_dir_end()
	return {
		"success": true,
		"message": "Listed %d entries under %s" % [results.size(), path],
		"path": path,
		"entries": results,
	}


func _execute_search_files(output: Dictionary) -> Dictionary:
	var query: String = str(output.get("query", ""))
	var root_path: String = str(output.get("root_path", "res://"))
	var extensions := output.get("extensions", [])
	var max_matches: int = int(output.get("max_matches", 50))
	if query.strip_edges().is_empty():
		return {"success": false, "message": "query is required"}
	if root_path.is_empty():
		root_path = "res://"
	if max_matches < 1:
		max_matches = 1
	if max_matches > 500:
		max_matches = 500

	var exts: Array[String] = []
	if extensions is Array:
		for e in extensions:
			var s := str(e).strip_edges()
			if s.is_empty():
				continue
			if not s.begins_with("."):
				s = "." + s
			exts.append(s.to_lower())

	var matches: Array = []
	var root_abs := _project_path_to_absolute(root_path)
	var stack: Array = [{"abs": root_abs, "res": root_path, "depth": 0}]
	while not stack.is_empty() and matches.size() < max_matches:
		var cur: Dictionary = stack.pop_back()
		var dir_abs: String = str(cur.get("abs", ""))
		var dir_res: String = str(cur.get("res", ""))
		var depth: int = int(cur.get("depth", 0))
		var da := DirAccess.open(dir_abs)
		if da == null:
			continue
		da.list_dir_begin()
		while matches.size() < max_matches:
			var name := da.get_next()
			if name.is_empty():
				break
			if name == "." or name == "..":
				continue
			var child_abs := dir_abs.path_join(name)
			var child_res := dir_res.trim_suffix("/").path_join(name)
			if da.current_is_dir():
				if depth < 50:
					stack.append({"abs": child_abs, "res": child_res, "depth": depth + 1})
				continue
			if exts.size() > 0:
				var ext := ("." + child_res.get_extension()).to_lower()
				if not exts.has(ext):
					continue
			var txt := _read_text_file_abs(child_abs)
			if txt.is_empty():
				continue
			if txt.find(query) == -1:
				continue
			var previews: Array[String] = []
			var lines := txt.split("\n")
			for i in range(lines.size()):
				if query in lines[i]:
					previews.append("%d:%s" % [i + 1, lines[i].strip_edges()])
					if previews.size() >= 3:
						break
			matches.append({"path": child_res, "previews": previews})
		da.list_dir_end()
	return {
		"success": true,
		"message": "Found %d matches for '%s' under %s" % [matches.size(), query, root_path],
		"query": query,
		"root_path": root_path,
		"matches": matches,
	}


func _preview_create_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	var overwrite: bool = output.get("overwrite", false)
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	var old_content := _read_text_file_abs(abs_path)
	if FileAccess.file_exists(abs_path) and not overwrite:
		return {"ok": false, "message": "File already exists and overwrite is false: %s" % path}
	return {
		"ok": true,
		"change": {
			"file_path": path,
			"change_type": "create" if not FileAccess.file_exists(abs_path) else "modify",
			"old_content": old_content,
			"new_content": content,
			"summary": "create %s" % path,
		}
	}


func _preview_write_file(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	var old_content := _read_text_file_abs(abs_path)
	return {
		"ok": true,
		"change": {
			"file_path": path,
			"change_type": "create" if not FileAccess.file_exists(abs_path) else "modify",
			"old_content": old_content,
			"new_content": content,
			"summary": "write %s" % path,
		}
	}


func _preview_apply_patch(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var old_string: String = output.get("old_string", "")
	var new_string: String = output.get("new_string", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := _project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "message": "File not found: %s" % path}
	var old_content := _read_text_file_abs(abs_path)
	if old_string not in old_content:
		return {"ok": false, "message": "old_string not found in file"}
	var new_content: String = old_content.replace(old_string, new_string)
	return {
		"ok": true,
		"change": {
			"file_path": path,
			"change_type": "modify",
			"old_content": old_content,
			"new_content": new_content,
			"summary": "patch %s" % path,
		}
	}


func _preview_create_script(output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var language: String = output.get("language", "gdscript")
	var extends_class: String = output.get("extends_class", "Node")
	var initial_content: String = output.get("initial_content", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var content: String
	if language == "csharp":
		content = "using Godot;\n\npublic partial class %s : %s\n{\n%s\n}\n" % [
			path.get_file().get_basename().replace(" ", ""),
			extends_class,
			initial_content
		]
	else:
		content = "extends %s\n\n%s" % [extends_class, initial_content]
	return _preview_write_file({"execute_on_client": true, "action": "write_file", "path": path, "content": content})


func _execute_create_node_sync(output: Dictionary) -> Dictionary:
	return {"success": false, "message": "create_node requires async execution; use execute_async from the dock."}


func _execute_create_node(output: Dictionary) -> Dictionary:
	if editor_interface == null:
		return {"success": false, "message": "Editor not available."}
	var prev_root: Node = editor_interface.get_edited_scene_root()
	var prev_scene_path := ""
	if prev_root and prev_root.scene_file_path != "":
		prev_scene_path = prev_root.scene_file_path
	var scene_path: String = output.get("scene_path", "")
	var parent_path: String = output.get("parent_path", "/root")
	var node_type: String = output.get("node_type", "Node")
	var node_name: String = output.get("node_name", "")
	if scene_path.is_empty() or node_type.is_empty():
		return {"success": false, "message": "scene_path and node_type are required"}
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return {"success": false, "message": "Scene not found: %s" % scene_path}
	editor_interface.open_scene_from_path(scene_path)
	await Engine.get_main_loop().process_frame
	var root: Node = editor_interface.get_edited_scene_root()
	if root == null:
		return {"success": false, "message": "No scene root."}
	var parent: Node = root
	if not parent_path.is_empty() and parent_path != "/" and parent_path != "/root":
		var path_trimmed := parent_path.trim_prefix("/root/").trim_prefix("/")
		if not path_trimmed.is_empty():
			parent = root.get_node_or_null(path_trimmed)
			if parent == null:
				parent = root.get_node_or_null(parent_path)
			if parent == null:
				return {"success": false, "message": "Parent node not found: %s" % parent_path}
	var new_node: Node = ClassDB.instantiate(node_type)
	if new_node == null:
		return {"success": false, "message": "Invalid node type: %s" % node_type}
	if not node_name.is_empty():
		new_node.name = node_name
	parent.add_child(new_node)
	new_node.owner = root
	editor_interface.save_scene()
	if not follow_agent and prev_scene_path != "" and prev_scene_path != scene_path:
		editor_interface.open_scene_from_path(prev_scene_path)
	return {"success": true, "message": "Added %s to %s" % [node_type, scene_path]}


func _execute_set_node_property_sync(output: Dictionary) -> Dictionary:
	return {"success": false, "message": "set_node_property requires async execution; use execute_async from the dock."}


func _execute_set_node_property(output: Dictionary) -> Dictionary:
	if editor_interface == null:
		return {"success": false, "message": "Editor not available."}
	var prev_root: Node = editor_interface.get_edited_scene_root()
	var prev_scene_path := ""
	if prev_root and prev_root.scene_file_path != "":
		prev_scene_path = prev_root.scene_file_path
	var scene_path: String = output.get("scene_path", "")
	var node_path: String = output.get("node_path", "")
	var property_name: String = output.get("property_name", "")
	var value = output.get("value")
	if scene_path.is_empty() or node_path.is_empty() or property_name.is_empty():
		return {"success": false, "message": "scene_path, node_path, property_name required"}
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return {"success": false, "message": "Scene not found: %s" % scene_path}
	editor_interface.open_scene_from_path(scene_path)
	await Engine.get_main_loop().process_frame
	var root: Node = editor_interface.get_edited_scene_root()
	if root == null:
		return {"success": false, "message": "No scene root."}
	var target: Node = root.get_node_or_null(node_path)
	if target == null:
		var path_trimmed := node_path.trim_prefix("/root/").trim_prefix("/")
		target = root.get_node_or_null(path_trimmed)
	if target == null:
		return {"success": false, "message": "Node not found: %s" % node_path}
	var parsed := _parse_property_value(value)
	if parsed == null and value != null:
		return {"success": false, "message": "Could not parse value for property"}
	# In Godot 4, set() returns void; check property exists and is writable first.
	if not _property_writable(target, property_name):
		return {"success": false, "message": "Property not found or read-only: %s" % property_name}
	target.set(property_name, parsed)
	editor_interface.save_scene()
	if not follow_agent and prev_scene_path != "" and prev_scene_path != scene_path:
		editor_interface.open_scene_from_path(prev_scene_path)
	return {"success": true, "message": "Set %s.%s" % [node_path, property_name]}


func _property_writable(obj: Object, prop: String) -> bool:
	for d in obj.get_property_list():
		if d.get("name", "") == prop:
			var usage: int = d.get("usage", 0) as int
			return (usage & PROPERTY_USAGE_READ_ONLY) == 0
	return false


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
