@tool
extends RefCounted
class_name GodotAILintService

## Lint service: backend call when configured, otherwise subprocess fallback.

func request_backend_lint(
	dock: GodotAIDock,
	rag_service_url: String,
	res_path: String
) -> Dictionary:
	var base := (rag_service_url as String).strip_edges().trim_suffix("/")
	if base.is_empty():
		# No backend: run Godot --script path --check-only in a subprocess and capture output.
		var sub := GodotAIServerLint.run_lint_via_godot_subprocess(res_path)
		var out_text := str(sub.get("output", "")).strip_edges()
		if dock:
			dock.set_last_lint_result(res_path, out_text)
		var ok := bool(sub.get("success", false))
		return {
			"success": ok,
			"message": "Lint passed" if ok else "Lint reported issues",
			"path": res_path,
			"output": out_text,
			"exit_code": int(sub.get("exit_code", -1))
		}
	var url := base + "/lint"
	var project_root_abs := ProjectSettings.globalize_path("res://")
	var body := JSON.stringify({"project_root_abs": project_root_abs, "path": res_path})
	var req := HTTPRequest.new()
	if dock:
		dock.add_child(req)
	req.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	var args: Array = await req.request_completed
	req.queue_free()
	if args[0] != HTTPRequest.RESULT_SUCCESS:
		var fail_msg := "Lint request failed (is the RAG backend running?)"
		if dock:
			dock.set_last_lint_result(res_path, fail_msg)
		return {
			"success": false,
			"message": fail_msg,
			"path": res_path,
			"output": fail_msg,
			"exit_code": -1
		}
	var resp_body: PackedByteArray = args[3]
	var json := JSON.new()
	if json.parse(resp_body.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		var invalid_msg := "Invalid lint response from backend"
		if dock:
			dock.set_last_lint_result(res_path, invalid_msg)
		return {
			"success": false,
			"message": invalid_msg,
			"path": res_path,
			"output": invalid_msg,
			"exit_code": -1
		}
	var d: Dictionary = json.data
	var ok := bool(d.get("success", false))
	var out_text := str(d.get("output", "")).strip_edges()
	if dock:
		dock.set_last_lint_result(res_path, out_text)
	return {
		"success": ok,
		"message": "Lint passed" if ok else "Lint reported issues",
		"path": res_path,
		"output": out_text,
		"exit_code": int(d.get("exit_code", -1))
	}

