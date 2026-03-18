@tool
extends RefCounted
class_name GodotAIDiffReview

## Opens a file in the Godot script editor and applies diff highlighting (green/yellow/red).
## Uses GodotAIDiffCalculator for line changes and EditorInterface for opening/focusing.
## Separation of concerns: this module only opens editor and applies highlights; data comes from caller.

const COLOR_ADD := Color(0.2, 0.5, 0.25, 0.35)           # green
const COLOR_MODIFY := Color(0.55, 0.5, 0.15, 0.4)      # yellow
const COLOR_REMOVE_REPLACE := Color(0.55, 0.2, 0.2, 0.4)  # red

var _editor_interface: EditorInterface = null
var _last_highlighted_path: String = ""

func _init(p_editor_interface: EditorInterface = null) -> void:
	_editor_interface = p_editor_interface


func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e


## Clear diff line backgrounds from the script we last highlighted. Call when user deselects or leaves the Changes tab.
func clear_highlights() -> void:
	if _editor_interface == null or _last_highlighted_path.is_empty():
		_last_highlighted_path = ""
		return
	var script_editor = _editor_interface.get_script_editor()
	if script_editor == null:
		_last_highlighted_path = ""
		return
	var current_script: Script = script_editor.get_current_script()
	if current_script == null:
		_last_highlighted_path = ""
		return
	var current_path := (current_script as Resource).resource_path.replace("\\", "/")
	if current_path != _last_highlighted_path and not current_path.ends_with(_last_highlighted_path) and not _last_highlighted_path.ends_with(current_path):
		_last_highlighted_path = ""
		return
	var current_editor = script_editor.get_current_editor()
	if current_editor == null:
		_last_highlighted_path = ""
		return
	var base_editor: Control = current_editor.get_base_editor()
	if base_editor == null or not (base_editor is CodeEdit):
		_last_highlighted_path = ""
		return
	var code_edit: CodeEdit = base_editor as CodeEdit
	var clear_color := Color(0, 0, 0, 0)
	for line_idx in range(code_edit.get_line_count()):
		code_edit.set_line_background_color(line_idx, clear_color)
	_last_highlighted_path = ""


## Open the file in the script editor, focus it, apply line background colors for the diff,
## and scroll to the first changed line. file_path should be res:// path.
## old_content/new_content are the before/after file contents.
## Returns true if opening and highlighting succeeded.
func open_and_show_diff(file_path: String, old_content: String, new_content: String) -> bool:
	if _editor_interface == null:
		return false
	var path_normalized := file_path.replace("\\", "/").strip_edges()
	if path_normalized.is_empty():
		return false

	var line_changes: Array = GodotAIDiffCalculator.compute_line_changes(old_content, new_content)

	# Skip loading paths that have no resource loader (e.g. .placeholder, directories)
	var base_name := path_normalized.get_file()
	if base_name == ".placeholder" or path_normalized.ends_with("/"):
		var fs_dock = _editor_interface.get_file_system_dock()
		if fs_dock != null and fs_dock.has_method("navigate_to_path"):
			fs_dock.call_deferred("navigate_to_path", path_normalized)
		return false

	# Open the file in the script editor (works for .gd and other script types)
	var script_res: Resource = null
	if path_normalized.begins_with("res://"):
		script_res = load(path_normalized) as Resource
	else:
		script_res = load("res://" + path_normalized) as Resource

	if script_res == null:
		# Not a loadable resource (e.g. text file); try FileSystem dock so user sees path
		var fs_dock = _editor_interface.get_file_system_dock()
		if fs_dock != null and fs_dock.has_method("navigate_to_path"):
			fs_dock.call_deferred("navigate_to_path", path_normalized)
		return false

	# Script or other resource: open in editor
	if script_res is Script:
		_editor_interface.edit_script(script_res as Script, -1, 0, true)
	else:
		_editor_interface.edit_resource(script_res)

	# Defer applying highlights and goto_line so the script editor tab is ready
	var first_line := GodotAIDiffCalculator.first_changed_line(line_changes)
	call_deferred("_apply_highlights_deferred", path_normalized, line_changes, first_line)

	return true


func _apply_highlights_deferred(expected_path: String, line_changes: Array, first_changed_line: int) -> void:
	if _editor_interface == null:
		return
	var script_editor = _editor_interface.get_script_editor()
	if script_editor == null:
		return
	var current_script: Script = script_editor.get_current_script()
	if current_script == null:
		return
	var current_path := (current_script as Resource).resource_path.replace("\\", "/")
	if current_path != expected_path and not current_path.ends_with(expected_path) and not expected_path.ends_with(current_path):
		return
	var current_editor = script_editor.get_current_editor()
	if current_editor == null:
		return
	var base_editor: Control = current_editor.get_base_editor()
	if base_editor == null or not (base_editor is CodeEdit):
		return
	var code_edit: CodeEdit = base_editor as CodeEdit

	var clear_color := Color(0, 0, 0, 0)
	var line_count := code_edit.get_line_count()
	for line_idx in range(line_count):
		var col: Color = clear_color
		if line_idx < line_changes.size():
			var ct := int(line_changes[line_idx])
			match ct:
				GodotAIDiffCalculator.LineChangeType.ADD:
					col = COLOR_ADD
				GodotAIDiffCalculator.LineChangeType.MODIFY:
					col = COLOR_MODIFY
				GodotAIDiffCalculator.LineChangeType.REMOVE_REPLACE:
					col = COLOR_REMOVE_REPLACE
		code_edit.set_line_background_color(line_idx, col)

	if first_changed_line >= 0:
		script_editor.goto_line(first_changed_line + 1)
	_last_highlighted_path = current_path
