@tool
extends RefCounted
class_name GodotAIImport

## Import operations: read_import_options, set_import_option.

static func execute_read_import_options(
	executor: GodotAIEditorToolExecutor, output: Dictionary
) -> Dictionary:
	var path: String = str(output.get("path", "")).strip_edges()
	if path.is_empty():
		return {"success": false, "message": "path is required"}
	if not path.begins_with("res://"):
		path = "res://" + path
	var import_path := path
	if not import_path.ends_with(".import"):
		import_path = path + ".import"
	var abs_path := executor.project_path_to_absolute(import_path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "No .import file found for: %s" % path}
	var content: String = GodotAIFile.read_text_file_abs(abs_path)
	return {
		"success": true,
		"message": "Read import options for %s" % path,
		"path": path,
		"import_path": import_path,
		"content": content,
	}


static func execute_set_import_option(
	executor: GodotAIEditorToolExecutor, output: Dictionary
) -> Dictionary:
	var path: String = str(output.get("path", "")).strip_edges()
	var key: String = str(output.get("key", "")).strip_edges()
	var value = output.get("value")
	if path.is_empty() or key.is_empty():
		return {"success": false, "message": "path and key are required"}
	if value == null:
		return {"success": false, "message": "value is required"}
	if not path.begins_with("res://"):
		path = "res://" + path
	var import_path := path
	if not import_path.ends_with(".import"):
		import_path = path + ".import"
	var abs_path := executor.project_path_to_absolute(import_path)
	if not FileAccess.file_exists(abs_path):
		return {"success": false, "message": "No .import file found for: %s" % path}
	var content: String = GodotAIFile.read_text_file_abs(abs_path)
	var value_str: String
	if value is bool:
		value_str = "true" if value else "false"
	elif value is int or value is float:
		value_str = str(value)
	else:
		value_str = str(value)
	var lines: PackedStringArray = content.split("\n")
	var in_params := false
	var key_found := false
	var new_lines: PackedStringArray = []
	for i in range(lines.size()):
		var line: String = lines[i]
		var stripped: String = line.strip_edges()
		if stripped.begins_with("["):
			if in_params and not key_found:
				new_lines.append("%s=%s" % [key, value_str])
				key_found = true
			in_params = stripped == "[params]"
			new_lines.append(line)
			continue
		if in_params:
			if stripped.begins_with(key + "="):
				new_lines.append("%s=%s" % [key, value_str])
				key_found = true
				continue
		new_lines.append(line)
	if in_params and not key_found:
		new_lines.append("%s=%s" % [key, value_str])
	var new_content := "\n".join(new_lines)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "message": "Failed to write: %s" % import_path}
	f.store_string(new_content)
	f.close()
	var norm_path := executor.normalize_res_path(import_path)
	return {
		"success": true,
		"message": "Set %s=%s for %s" % [key, value_str, path],
		"path": path,
		"key": key,
		"value": value_str,
		"edit_record": {
			"action_type": "set_import_option",
			"file_path": norm_path,
			"change_type": "modify",
			"old_content": content,
			"new_content": new_content,
			"summary": "Set import %s=%s for %s" % [key, value_str, path],
		}
	}
