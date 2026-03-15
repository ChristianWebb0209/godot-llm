@tool
extends RefCounted
class_name GodotAIEditorToolExecutor

## Dispatches editor tool payloads to action modules. Public API: execute, execute_async, preview_file_change.

var editor_interface: EditorInterface = null
var follow_agent: bool = true

var _node_actions: GodotAINode


func _init(p_editor_interface: EditorInterface = null) -> void:
	editor_interface = p_editor_interface
	_node_actions = GodotAINode.new(self) if p_editor_interface else null


func project_path_to_absolute(res_path: String) -> String:
	if res_path.begins_with("res://"):
		return ProjectSettings.globalize_path(res_path)
	return res_path


func normalize_res_path(res_path: String) -> String:
	var p := res_path.strip_edges()
	if p.is_empty():
		return p
	if not p.begins_with("res://"):
		p = "res://" + p
	return p


func read_text_file_abs(abs_path: String) -> String:
	return GodotAIFile.read_text_file_abs(abs_path)


func execute(output: Dictionary) -> Dictionary:
	if not output.get("execute_on_client", false):
		return {"success": false, "message": "Not a client action."}
	var action: String = output.get("action", "")
	match action:
		"read_file":
			return GodotAIFile.execute_read_file(self, output)
		"list_directory":
			return GodotAIFS.execute_list_directory(self, output)
		"list_files":
			return GodotAIFS.execute_list_files(self, output)
		"search_files":
			return GodotAIFS.execute_search_files(self, output)
		"read_import_options":
			return GodotAIImport.execute_read_import_options(self, output)
		"delete_file":
			return GodotAIFile.execute_delete_file(self, output)
		"create_file":
			return GodotAIFile.execute_create_file(self, output)
		"write_file":
			return GodotAIFile.execute_write_file(self, output)
		"append_to_file":
			return GodotAIFile.execute_append_to_file(self, output)
		"apply_patch":
			return GodotAIFile.execute_apply_patch(self, output)
		"create_script":
			return GodotAIFile.execute_create_script(self, output)
		"create_node":
			return _node_actions.execute_create_node_sync(output) if _node_actions else {"success": false, "message": "Editor not available."}
		"modify_attribute":
			return _node_actions.execute_modify_attribute(output) if _node_actions else {"success": false, "message": "Editor not available."}
		"lint_file":
			return _execute_lint_file(output)
		_:
			return {"success": false, "message": "Unknown action: %s" % action}


func execute_async(output: Dictionary) -> Dictionary:
	if not output.get("execute_on_client", false):
		return {"success": false, "message": "Not a client action."}
	var action: String = output.get("action", "")
	match action:
		"read_file":
			return GodotAIFile.execute_read_file(self, output)
		"list_directory":
			return GodotAIFS.execute_list_directory(self, output)
		"list_files":
			return GodotAIFS.execute_list_files(self, output)
		"search_files":
			return GodotAIFS.execute_search_files(self, output)
		"read_import_options":
			return GodotAIImport.execute_read_import_options(self, output)
		"delete_file":
			return GodotAIFile.execute_delete_file(self, output)
		"create_file":
			return GodotAIFile.execute_create_file(self, output)
		"write_file":
			return GodotAIFile.execute_write_file(self, output)
		"append_to_file":
			return GodotAIFile.execute_append_to_file(self, output)
		"apply_patch":
			return GodotAIFile.execute_apply_patch(self, output)
		"create_script":
			return GodotAIFile.execute_create_script(self, output)
		"create_node":
			return await _node_actions.execute_create_node(output) if _node_actions else {"success": false, "message": "Editor not available."}
		"modify_attribute":
			return await _node_actions.execute_modify_attribute_async(output) if _node_actions else {"success": false, "message": "Editor not available."}
		"lint_file":
			return _execute_lint_file(output)
		_:
			return {"success": false, "message": "Unknown action: %s" % action}


func preview_file_change(output: Dictionary) -> Dictionary:
	return GodotAIPreviews.preview(self, output)


func set_follow_agent(enabled: bool) -> void:
	follow_agent = enabled


func _execute_lint_file(_output: Dictionary) -> Dictionary:
	return {"success": false, "message": "Lint is run via the RAG backend. Use the dock's lint flow.", "path": "", "output": ""}
