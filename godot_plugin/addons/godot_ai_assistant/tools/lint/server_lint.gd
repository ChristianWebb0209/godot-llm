@tool
extends RefCounted
class_name GodotAIServerLint

## Lint: try local (editor) first; only call backend when we need full error text.
## Results are stored on the dock so they go to RAG (context) on the next query.

static func read_text_res(path: String) -> String:
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


static func should_lint_path(path: String) -> bool:
	var p := path.to_lower()
	return p.ends_with(".gd") or p.ends_with(".cs") or p.ends_with(".gdshader")


## Format lint output for user: "0 errors" or "2 errors, 1 warning" etc.
static func format_lint_summary(lint_ok: bool, raw_output: String) -> String:
	if lint_ok:
		if raw_output.is_empty():
			return "Lint passed (0 errors)"
		var err := _count_lint_lines(raw_output, "error")
		var warn := _count_lint_lines(raw_output, "warning")
		if err == 0 and warn == 0:
			return "Lint passed (0 errors)"
		return "Lint passed (%d error(s), %d warning(s) in output)" % [err, warn]
	# Failed
	if raw_output.is_empty():
		return "Lint failed (no output)"
	var err := _count_lint_lines(raw_output, "error")
	var warn := _count_lint_lines(raw_output, "warning")
	var parts: Array[String] = []
	if err > 0:
		parts.append("%d error(s)" % err)
	if warn > 0:
		parts.append("%d warning(s)" % warn)
	if parts.is_empty():
		return "Lint failed (see output)"
	return "Lint: " + ", ".join(parts)


static func _count_lint_lines(txt: String, word: String) -> int:
	var n := 0
	var lines := txt.split("\n")
	for line in lines:
		if word in line.to_lower():
			n += 1
	return n


## Run lint using the editor's own parser first (Logger capture on reload()).
## Same errors the script editor shows; no subprocess. Fall back to backend/subprocess only for non-.gd.
## Returns { ok: bool, exit_code: int, output: String }.
static func run_lint(dock: GodotAIDock, res_path: String) -> Dictionary:
	var res := _try_local_lint_with_editor_errors(res_path)
	if not res.is_empty():
		dock.set_last_lint_result(res_path, res.get("output", ""))
		return res
	var d := await dock.request_backend_lint(res_path)
	return {
		"ok": d.get("success", false),
		"exit_code": d.get("exit_code", -1),
		"output": d.get("output", ""),
	}


## Local-only lint: in-editor Logger capture on reload(); no backend, no subprocess.
## Returns { ok: bool, exit_code: int, output: String }. For .gd we get real error text from the editor.
static func run_lint_local_only(res_path: String) -> Dictionary:
	var res := _try_local_lint_with_editor_errors(res_path)
	if not res.is_empty():
		return {"ok": res.get("ok", true), "exit_code": res.get("exit_code", 0), "output": res.get("output", "")}
	var fallback := _try_local_lint(res_path)
	if fallback.has("ok"):
		return {"ok": fallback.get("ok", true), "exit_code": fallback.get("exit_code", 0), "output": fallback.get("output", "")}
	return {"ok": false, "exit_code": -1, "output": "Lint failed (see Output for details)."}


## Lint in the current editor process (no subprocess). We only get pass/fail, not error text.
## Returns {} if we need to fall back to backend (errors or not GDScript); otherwise { ok: bool, output: String }.
static func _try_local_lint(res_path: String) -> Dictionary:
	var p := res_path
	if p.begins_with("res://"):
		p = p.substr(6)
	if not p.to_lower().ends_with(".gd"):
		return {}
	var script_res: GDScript = load("res://" + p) as GDScript
	if script_res == null:
		return {}
	var err := script_res.reload()
	if err == OK:
		return {"ok": true, "exit_code": 0, "output": ""}
	return {}


## Lint using the editor's own parser: capture errors via OS Logger when we call reload().
## Same errors that appear in the editor Output panel; no subprocess or backend needed.
## Returns {} for non-.gd or if script fails to load; otherwise { ok: bool, output: String }.
static func _try_local_lint_with_editor_errors(res_path: String) -> Dictionary:
	var p := res_path
	if p.begins_with("res://"):
		p = p.substr(6)
	if not p.to_lower().ends_with(".gd"):
		return {}
	var script_res: GDScript = load("res://" + p) as GDScript
	if script_res == null:
		return {}
	var logger := GodotAILintCaptureLogger.new(res_path)
	OS.add_logger(logger)
	var err := script_res.reload()
	OS.remove_logger(logger)
	var captured := logger.get_and_clear_captured()
	var output := "\n".join(captured)
	if err == OK and output.is_empty():
		return {"ok": true, "exit_code": 0, "output": ""}
	return {"ok": false, "exit_code": 1, "output": output if not output.is_empty() else "Parse failed (no message)."}


## Run Godot as a subprocess (same binary as current editor) with --script path --check-only
## and capture stdout+stderr. Use when backend is unavailable so the plugin can still report real errors.
## Returns { success: bool, output: String, exit_code: int }.
static func run_lint_via_godot_subprocess(res_path: String) -> Dictionary:
	var path_stripped := res_path.strip_edges()
	if path_stripped.begins_with("res://"):
		path_stripped = path_stripped.substr(6)
	if path_stripped.is_empty() or not path_stripped.to_lower().ends_with(".gd"):
		return {"success": false, "output": "Only .gd scripts are supported for subprocess lint.", "exit_code": -1}
	var godot_bin := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	if project_root.is_empty():
		return {"success": false, "output": "Could not resolve project path.", "exit_code": -1}
	# Temp file for capture (same approach as backend)
	var tmp_dir: String
	if OS.get_name() == "Windows":
		tmp_dir = OS.get_environment("TEMP")
		if tmp_dir.is_empty():
			tmp_dir = OS.get_environment("TMP")
	else:
		tmp_dir = "/tmp"
	if tmp_dir.is_empty():
		tmp_dir = OS.get_user_data_dir()
	var out_file := (tmp_dir + "/godot_ai_lint_%d.txt") % Time.get_ticks_msec()
	var exit_code: int
	if OS.get_name() == "Windows":
		# cmd /c "path\to\godot.exe" --headless --editor --path "project" --script "path" --check-only > out 2>&1
		var cmd_str := "\"%s\" --headless --editor --path \"%s\" --script \"%s\" --check-only > \"%s\" 2>&1" % [godot_bin, project_root, path_stripped, out_file]
		exit_code = OS.execute("cmd", ["/c", cmd_str], [], true)
	else:
		var cmd_str := "'%s' --headless --editor --path '%s' --script '%s' --check-only > '%s' 2>&1" % [godot_bin, project_root, path_stripped, out_file]
		exit_code = OS.execute("sh", ["-c", cmd_str], [], true)
	var output := ""
	if FileAccess.file_exists(out_file):
		var f := FileAccess.open(out_file, FileAccess.READ)
		if f != null:
			output = f.get_as_text().strip_edges()
			f.close()
		DirAccess.remove_absolute(out_file)
	return {
		"success": exit_code == 0,
		"output": output,
		"exit_code": exit_code
	}
