@tool
extends RefCounted
class_name GodotAIPreviews

## Preview file changes without applying: create_file, write_file, append_to_file, apply_patch, create_script, delete_file.

static func preview(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	if not output.get("execute_on_client", false):
		return {"ok": false, "message": "Not a client action."}
	var action: String = output.get("action", "")
	match action:
		"create_file":
			return preview_create_file(executor, output)
		"write_file":
			return preview_write_file(executor, output)
		"append_to_file":
			return preview_append_to_file(executor, output)
		"apply_patch":
			return preview_apply_patch(executor, output)
		"create_script":
			return preview_create_script(executor, output)
		"delete_file":
			return preview_delete_file(executor, output)
		_:
			return {"ok": false, "message": "Not a file edit action: %s" % action}


static func preview_create_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	var overwrite: bool = output.get("overwrite", false)
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	var old_content: String = GodotAIFile.read_text_file_abs(abs_path)
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


static func preview_write_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	var old_content: String = GodotAIFile.read_text_file_abs(abs_path)
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


static func preview_append_to_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var content: String = output.get("content", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	var old_content: String = GodotAIFile.read_text_file_abs(abs_path)
	var new_content: String = old_content + content
	return {
		"ok": true,
		"change": {
			"file_path": path,
			"change_type": "create" if not FileAccess.file_exists(abs_path) else "modify",
			"old_content": old_content,
			"new_content": new_content,
			"summary": "append %s" % path,
		}
	}


static func preview_apply_patch(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	var old_string: String = output.get("old_string", "")
	var new_string: String = output.get("new_string", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "message": "File not found: %s" % path}
	var old_content: String = GodotAIFile.read_text_file_abs(abs_path)
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


static func preview_create_script(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var content: String = GodotAIFile.get_create_script_content(output)
	return preview_write_file(executor, {"execute_on_client": true, "action": "write_file", "path": path, "content": content})


static func preview_delete_file(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "")
	if path.is_empty():
		return {"ok": false, "message": "path is required"}
	var abs_path := executor.project_path_to_absolute(path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "message": "File not found: %s" % path}
	var old_content: String = GodotAIFile.read_text_file_abs(abs_path)
	return {
		"ok": true,
		"change": {
			"file_path": path,
			"change_type": "delete",
			"old_content": old_content,
			"new_content": "",
			"summary": "delete %s" % path,
		}
	}
