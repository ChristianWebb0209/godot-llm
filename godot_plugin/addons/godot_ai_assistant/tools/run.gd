@tool
extends RefCounted
class_name GodotAIRun

## Run terminal commands and Godot headlessly; capture exit code, stdout, and stderr
## so the model can "observe" output and fix (write → run → observe → fix loop).

static func _get_shell_and_args(full_command: String) -> PackedStringArray:
	if OS.get_name() == "Windows":
		return PackedStringArray(["cmd.exe", "/c", full_command])
	return PackedStringArray(["/bin/sh", "-c", full_command])


static func _quote_path(p: String) -> String:
	if p.is_empty():
		return p
	# Quote for shell so paths with spaces work; escape double quotes
	var s := p.replace("\\", "\\\\").replace("\"", "\\\"")
	if p.contains(" ") or p.contains("\""):
		return "\"" + s + "\""
	return p


## Run a shell command with stdout and stderr redirected to temp_file; wait up to timeout_sec; return { exit_code, stdout }
static func _run_with_capture(full_command: String, temp_file_path: String, timeout_sec: float) -> Dictionary:
	var args := _get_shell_and_args(full_command)
	var rest := PackedStringArray()
	for i in range(1, args.size()):
		rest.append(args[i])
	var pid: int = OS.create_process(args[0], rest)
	if pid <= 0:
		return {"exit_code": -1, "stdout": "", "error": "Failed to start process"}
	var main_loop := Engine.get_main_loop()
	var elapsed: float = 0.0
	while OS.is_process_running(pid) and elapsed < timeout_sec:
		await main_loop.create_timer(0.1).timeout
		elapsed += 0.1
	var exit_code: int = 0
	if OS.is_process_running(pid):
		OS.kill(pid)
		exit_code = -1
	else:
		exit_code = OS.get_process_exit_code(pid)
	var stdout_text: String = ""
	if FileAccess.file_exists(temp_file_path):
		var f := FileAccess.open(temp_file_path, FileAccess.READ)
		if f:
			stdout_text = f.get_as_text()
			f.close()
		DirAccess.remove_absolute(temp_file_path)
	return {"exit_code": exit_code, "stdout": stdout_text}


static func execute_run_terminal_command(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var command: String = str(output.get("command", output.get("cmd", ""))).strip_edges()
	var timeout_sec: float = float(output.get("timeout_seconds", 60))
	if command.is_empty():
		return {"success": false, "message": "command is required"}
	var temp_path: String = OS.get_cache_dir().path_join("godot_ai_run_stdout.txt")
	# Redirect stdout and stderr into one file so the model sees all output
	var wrapped: String
	if OS.get_name() == "Windows":
		wrapped = command + " > " + _quote_path(temp_path) + " 2>&1"
	else:
		wrapped = command + " > " + _quote_path(temp_path) + " 2>&1"
	var cap := await _run_with_capture(wrapped, temp_path, timeout_sec)
	var stdout_text: String = str(cap.get("stdout", "")).strip_edges()
	var exit_code: int = int(cap.get("exit_code", -1))
	var msg := "Command finished with exit code %d." % exit_code
	if stdout_text.length() > 0:
		msg += "\n\nOutput:\n" + stdout_text
	return {
		"success": exit_code == 0,
		"message": msg,
		"exit_code": exit_code,
		"command": command,
		"stdout": stdout_text,
	}


static func execute_run_godot_headless(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var scene_path: String = str(output.get("scene_path", output.get("script_path", ""))).strip_edges()
	var timeout_sec: float = float(output.get("timeout_seconds", 30))
	if scene_path.is_empty():
		return {"success": false, "message": "scene_path or script_path is required"}
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	var project_path: String = ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	var godot_exe: String = OS.get_executable_path()
	var temp_path: String = OS.get_cache_dir().path_join("godot_ai_run_stdout.txt")
	var cmd: String = _quote_path(godot_exe) + " --headless --path " + _quote_path(project_path) + " " + _quote_path(scene_path) + " > " + _quote_path(temp_path) + " 2>&1"
	var cap := await _run_with_capture(cmd, temp_path, timeout_sec)
	var stdout_text: String = str(cap.get("stdout", "")).strip_edges()
	var exit_code: int = int(cap.get("exit_code", -1))
	var msg := "Godot headless finished with exit code %d." % exit_code
	if stdout_text.length() > 0:
		msg += "\n\nOutput:\n" + stdout_text
	return {
		"success": exit_code == 0,
		"message": msg,
		"exit_code": exit_code,
		"scene_path": scene_path,
		"stdout": stdout_text,
	}


static func execute_run_scene(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var scene_path: String = str(output.get("scene_path", "")).strip_edges()
	var timeout_sec: float = float(output.get("timeout_seconds", 30))
	if scene_path.is_empty():
		return {"success": false, "message": "scene_path is required"}
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	var project_path: String = ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	var godot_exe: String = OS.get_executable_path()
	var temp_path: String = OS.get_cache_dir().path_join("godot_ai_run_stdout.txt")
	var cmd: String = _quote_path(godot_exe) + " --headless --path " + _quote_path(project_path) + " " + _quote_path(scene_path) + " > " + _quote_path(temp_path) + " 2>&1"
	var cap := await _run_with_capture(cmd, temp_path, timeout_sec)
	var stdout_text: String = str(cap.get("stdout", "")).strip_edges()
	var exit_code: int = int(cap.get("exit_code", -1))
	var msg := "Scene run finished with exit code %d." % exit_code
	if stdout_text.length() > 0:
		msg += "\n\nOutput:\n" + stdout_text
	return {
		"success": exit_code == 0,
		"message": msg,
		"exit_code": exit_code,
		"scene_path": scene_path,
		"stdout": stdout_text,
	}
