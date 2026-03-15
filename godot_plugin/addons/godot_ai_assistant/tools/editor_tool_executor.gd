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
		"grep_search":
			return GodotAIFS.execute_grep_search(self, output)
		"run_terminal_command":
			return {"success": false, "message": "Use async execution for run_terminal_command."}
		"run_godot_headless":
			return {"success": false, "message": "Use async execution for run_godot_headless."}
		"run_scene":
			return {"success": false, "message": "Use async execution for run_scene."}
		"get_node_tree":
			return GodotAISceneTree.execute_get_node_tree(self, output)
		"get_signals":
			return GodotAISignals.execute_get_signals(self, output)
		"connect_signal":
			return GodotAISignals.execute_connect_signal(self, output)
		"get_export_vars":
			return GodotAIInspector.execute_get_export_vars(self, output)
		"check_errors":
			return GodotAIEditorErrors.execute_check_errors(self, output)
		"get_project_settings":
			return GodotAIProject.execute_get_project_settings(self, output)
		"get_autoloads":
			return GodotAIProject.execute_get_autoloads(self, output)
		"get_input_map":
			return GodotAIProject.execute_get_input_map(self, output)
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
		"grep_search":
			return GodotAIFS.execute_grep_search(self, output)
		"run_terminal_command":
			return await GodotAIRun.execute_run_terminal_command(self, output)
		"run_godot_headless":
			return await GodotAIRun.execute_run_godot_headless(self, output)
		"run_scene":
			return await GodotAIRun.execute_run_scene(self, output)
		"get_node_tree":
			return GodotAISceneTree.execute_get_node_tree(self, output)
		"get_signals":
			return GodotAISignals.execute_get_signals(self, output)
		"connect_signal":
			return GodotAISignals.execute_connect_signal(self, output)
		"get_export_vars":
			return GodotAIInspector.execute_get_export_vars(self, output)
		"check_errors":
			return GodotAIEditorErrors.execute_check_errors(self, output)
		"get_project_settings":
			return GodotAIProject.execute_get_project_settings(self, output)
		"get_autoloads":
			return GodotAIProject.execute_get_autoloads(self, output)
		"get_input_map":
			return GodotAIProject.execute_get_input_map(self, output)
		_:
			return {"success": false, "message": "Unknown action: %s" % action}


func preview_file_change(output: Dictionary) -> Dictionary:
	return GodotAIPreviews.preview(self, output)


func set_follow_agent(enabled: bool) -> void:
	follow_agent = enabled


func _execute_lint_file(_output: Dictionary) -> Dictionary:
	return {"success": false, "message": "Lint is run via the RAG backend. Use the dock's lint flow.", "path": "", "output": ""}
