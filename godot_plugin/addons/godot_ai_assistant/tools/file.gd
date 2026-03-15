@tool
extends RefCounted
class_name GodotAIFile

## File operations for editor tool executor: create_file, write_file, apply_patch, create_script, delete_file, read_file.

const MAX_FILE_CONTENT_BYTES := 2 * 1024 * 1024  # 2MB

static func read_text_file_abs(abs_path: String) -> String:
	if not FileAccess.file_exists(abs_path):
		return ""
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


static func execute_create_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	var overwrite: bool = output.get("overwrite", false)
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	var old_content := ""
	if FileAccess.file_exists(abs_path):
		old_content = read_text_file_abs(abs_path)
	if FileAccess.file_exists(abs_path) and not overwrite:
		return {"success": false, "message": "File already exists and overwrite is false: %s" % path}
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(executor.project_path_to_absolute(dir))
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(content)
	f.close()
	if executor.editor_interface and executor.follow_agent:
		var res := load(path)
		if res:
			executor.editor_interface.edit_resource(res)
	var norm_path := executor.normalize_res_path(path)
	return {
		"success": true,
		"message": "Created: %s" % path,
		"edit_record": {
			"action_type": "create_file",
			"file_path": norm_path,
			"change_type": "create",
			"old_content": old_content,
			"new_content": content,
			"summary": "Created: %s" % path,
		}
	}


static func execute_write_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	if content.length() > MAX_FILE_CONTENT_BYTES:
		return {"success": false, "message": "Content too large (%d bytes, max %d). Refusing to avoid crash." % [content.length(), MAX_FILE_CONTENT_BYTES]}
	var abs_path := executor.project_path_to_absolute(path)
	var old_content := ""
	if FileAccess.file_exists(abs_path):
		old_content = read_text_file_abs(abs_path)
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(executor.project_path_to_absolute(dir))
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(content)
	f.close()
	if executor.editor_interface and executor.follow_agent:
		var res := load(path)
		if res:
			executor.editor_interface.edit_resource(res)
	var norm_path := executor.normalize_res_path(path)
	return {
		"success": true,
		"message": "Wrote: %s" % path,
		"edit_record": {
			"action_type": "write_file",
			"file_path": norm_path,
			"change_type": "modify",
			"old_content": old_content,
			"new_content": content,
			"summary": "Wrote: %s" % path,
		}
	}


static func execute_append_to_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	var old_content := ""
	if FileAccess.file_exists(abs_path):
		old_content = read_text_file_abs(abs_path)
	var new_content := old_content + content
	if new_content.length() > MAX_FILE_CONTENT_BYTES:
		return {"success": false, "message": "Resulting content too large (%d bytes, max %d)." % [new_content.length(), MAX_FILE_CONTENT_BYTES]}
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(executor.project_path_to_absolute(dir))
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(new_content)
	f.close()
	if executor.editor_interface and executor.follow_agent:
		var res := load(path)
		if res:
			executor.editor_interface.edit_resource(res)
	var norm_path := executor.normalize_res_path(path)
	return {
		"success": true,
		"message": "Appended: %s" % path,
		"edit_record": {
			"action_type": "append_to_file",
			"file_path": norm_path,
			"change_type": "modify",
			"old_content": old_content,
			"new_content": new_content,
			"summary": "Appended: %s" % path,
		}
	}


static func _apply_unified_diff_gd(old_content: String, diff_text: String) -> String:
	var lines: PackedStringArray = diff_text.split("\n")
	var hunks: Array = []  # [ { old_start, old_len, new_lines } ]
	var i := 0
	while i < lines.size():
		var line: String = lines[i]
		if line.begins_with("@@ "):
			var parts: PackedStringArray = line.split(" ", false, 2)
			if parts.size() < 2:
				return ""
			var old_part: String = parts[1].strip_edges()
			if old_part.begins_with("-"):
				old_part = old_part.substr(1).strip_edges()
			var old_parts: PackedStringArray = old_part.split(",")
			var old_start: int = int(old_parts[0])
			var old_len: int = int(old_parts[1]) if old_parts.size() > 1 else 1
			i += 1
			var hunk_new: PackedStringArray = []
			var old_count := 0
			while i < lines.size() and not lines[i].begins_with("@@"):
				var ln: String = lines[i]
				if ln.begins_with(" ") or ln.begins_with("+"):
					hunk_new.append(ln.substr(1) if ln.length() > 1 else "")
				if ln.begins_with(" ") or ln.begins_with("-"):
					old_count += 1
				i += 1
			if old_count != old_len:
				return ""
			hunks.append({"old_start": old_start, "old_len": old_len, "new_lines": hunk_new})
		else:
			i += 1
	if hunks.is_empty():
		return ""
	var old_lines: PackedStringArray = old_content.split("\n")
	var new_lines: PackedStringArray = []
	var pos := 0
	for h in hunks:
		var old_start: int = h.old_start
		var old_len: int = h.old_len
		var hunk_new: PackedStringArray = h.new_lines
		var old_idx: int = maxi(0, old_start - 1)
		for j in range(pos, old_idx):
			if j < old_lines.size():
				new_lines.append(old_lines[j])
		for k in range(hunk_new.size()):
			new_lines.append(hunk_new[k])
		pos = old_idx + old_len
	for j in range(pos, old_lines.size()):
		new_lines.append(old_lines[j])
	var result: String = "\n".join(new_lines)
	if old_content.ends_with("\n"):
		result += "\n"
	return result


static func execute_apply_patch(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var diff_text: String = str(output.get("diff", "")).strip_edges()
	var old_string: String = output.get("old_string", "")
	var new_string: String = output.get("new_string", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "File not found: %s" % path}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return {"success": false, "message": "Failed to open for read: %s" % path}
	var old_content: String = f.get_as_text()
	f.close()
	if old_content.length() > MAX_FILE_CONTENT_BYTES:
		return {"success": false, "message": "File too large to patch (%d bytes, max %d)." % [old_content.length(), MAX_FILE_CONTENT_BYTES]}
	var new_content: String
	if not diff_text.is_empty():
		new_content = _apply_unified_diff_gd(old_content, diff_text)
		if new_content.is_empty():
			return {"success": false, "message": "Failed to apply unified diff"}
	else:
		if old_string not in old_content:
			return {"success": false, "message": "old_string not found in file"}
		# Replace only first occurrence and avoid double-apply (e.g. "var x: T" -> "var x: T = null" applied twice).
		var idx := old_content.find(old_string)
		if idx < 0:
			return {"success": false, "message": "old_string not found in file"}
		var after_old: String = old_content.substr(idx + old_string.length(), 32).strip_edges()
		# If what follows old_string looks like an assignment, the change may already be applied; skip replace.
		if after_old.begins_with("=") and new_string.length() > old_string.length() and new_string.begins_with(old_string):
			new_content = old_content
		else:
			new_content = old_content.substr(0, idx) + new_string + old_content.substr(idx + old_string.length())
	if new_content.length() > MAX_FILE_CONTENT_BYTES:
		return {"success": false, "message": "Resulting content too large (%d bytes, max %d)." % [new_content.length(), MAX_FILE_CONTENT_BYTES]}
	f = FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to open for write: %s" % path}
	f.store_string(new_content)
	f.close()
	if executor.editor_interface and executor.follow_agent:
		var res := load(path)
		if res:
			executor.editor_interface.edit_resource(res)
	var norm_path := executor.normalize_res_path(path)
	return {
		"success": true,
		"message": "Patched: %s" % path,
		"edit_record": {
			"action_type": "apply_patch",
			"file_path": norm_path,
			"change_type": "modify",
			"old_content": old_content,
			"new_content": new_content,
			"summary": "Patched: %s" % path,
		}
	}


## Template name -> { extends: String, body_gd: String, body_cs: String }. Body is prepended to initial_content.
const _SCRIPT_TEMPLATES: Dictionary = {
	"character_2d": {"extends": "CharacterBody2D", "body_gd": "func _physics_process(delta):\n\tpass\n\n", "body_cs": "public override void _PhysicsProcess(double delta)\n\t{\n\t}\n\n"},
	"character_3d": {"extends": "CharacterBody3D", "body_gd": "func _physics_process(delta):\n\tpass\n\n", "body_cs": "public override void _PhysicsProcess(double delta)\n\t{\n\t}\n\n"},
	"control": {"extends": "Control", "body_gd": "", "body_cs": ""},
	"area_2d": {"extends": "Area2D", "body_gd": "", "body_cs": ""},
	"area_3d": {"extends": "Area3D", "body_gd": "", "body_cs": ""},
	"node": {"extends": "Node", "body_gd": "", "body_cs": ""},
}


## Build full script content for create_script (used by execute and preview).
static func get_create_script_content(output: Dictionary) -> String:
	var path: String = output.get("path", "")
	var language: String = output.get("language", "gdscript")
	var extends_class: String = output.get("extends_class", "Node")
	var initial_content: String = output.get("initial_content", "")
	var template_key: String = str(output.get("template", "")).strip_edges().to_lower()
	if not template_key.is_empty() and _SCRIPT_TEMPLATES.has(template_key):
		var t: Dictionary = _SCRIPT_TEMPLATES[template_key]
		extends_class = t.get("extends", extends_class)
		var body: String = t.get("body_gd", "") if language == "gdscript" else t.get("body_cs", "")
		initial_content = body + initial_content
	if language == "csharp":
		return "using Godot;\n\npublic partial class %s : %s\n{\n%s\n}\n" % [
			path.get_file().get_basename().replace(" ", ""),
			extends_class,
			initial_content
		]
	return "extends %s\n\n%s" % [extends_class, initial_content]


static func execute_create_script(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var content: String = get_create_script_content(output)
	var result := execute_write_file(executor, {"path": path, "content": content})
	if result.get("success", false) and result.has("edit_record"):
		result["edit_record"]["action_type"] = "create_script"
		result["edit_record"]["summary"] = "Created script: %s" % path
		result["message"] = "Created script: %s" % path
	return result


static func execute_read_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "File not found: %s" % path}
	var content := read_text_file_abs(abs_path)
	return {
		"success": true,
		"message": "Read: %s (%d chars)" % [path, content.length()],
		"path": path,
		"content": content,
	}


static func execute_delete_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "File not found: %s" % path}
	var old_content := read_text_file_abs(abs_path)
	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		return {"success": false, "message": "Failed to delete: %s (err=%d)" % [path, int(err)]}
	var norm_path := executor.normalize_res_path(path)
	return {
		"success": true,
		"message": "Deleted: %s" % path,
		"edit_record": {
			"action_type": "delete_file",
			"file_path": norm_path,
			"change_type": "delete",
			"old_content": old_content,
			"new_content": "",
			"summary": "Deleted: %s" % path,
		}
	}
