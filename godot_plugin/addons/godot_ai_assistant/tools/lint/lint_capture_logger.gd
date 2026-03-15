@tool
extends Logger
class_name GodotAILintCaptureLogger

## Captures script/shader errors emitted by the engine during script.reload() so the
## plugin can return them to the LLM without subprocess or backend. Used by server_lint.

var _target_path_normalized: String = ""
var _captured: Array[String] = []
var _mutex: Mutex = Mutex.new()


func _init(target_res_path: String) -> void:
	var p := (target_res_path as String).strip_edges()
	if p.begins_with("res://"):
		p = p.substr(6)
	if p.is_empty():
		_target_path_normalized = ""
		return
	var project_root := ProjectSettings.globalize_path("res://")
	_target_path_normalized = project_root.path_join(p).replace("\\", "/")


func _log_message(_message: String, _error: bool) -> void:
	pass


func _log_error(
	_function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array
) -> void:
	var want_type := error_type == Logger.ERROR_TYPE_SCRIPT or error_type == Logger.ERROR_TYPE_WARNING
	want_type = want_type or error_type == Logger.ERROR_TYPE_SHADER
	if not want_type:
		return
	if _target_path_normalized.is_empty():
		return
	var file_norm: String
	if file.begins_with("res://"):
		var root := ProjectSettings.globalize_path("res://")
		file_norm = root.path_join(file.substr(6)).replace("\\", "/")
	else:
		file_norm = file.replace("\\", "/")
	if file_norm != _target_path_normalized:
		return
	var msg: String = rationale if not rationale.is_empty() else code
	var is_err := error_type == Logger.ERROR_TYPE_SCRIPT or error_type == Logger.ERROR_TYPE_SHADER
	var kind := "error" if is_err else "warning"
	var line_str := "%d: %s: %s" % [line, kind, msg]
	_mutex.lock()
	_captured.append(line_str)
	_mutex.unlock()


## Returns captured lines and clears the buffer. Thread-safe.
func get_and_clear_captured() -> PackedStringArray:
	_mutex.lock()
	var out := PackedStringArray()
	for s in _captured:
		out.append(s)
	_captured.clear()
	_mutex.unlock()
	return out
