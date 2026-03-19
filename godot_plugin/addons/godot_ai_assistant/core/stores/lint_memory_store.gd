@tool
extends RefCounted
class_name GodotAILintMemoryStore

## Client-side "lint repair memory":
## Stores past lint failures + the fix explanation/content so the plugin can
## inject similar repair context into the request payload.
##
## Stored under:
## - user://godot_ai_assistant/lint_memory/lint_memory.json

const ROOT_DIR := "user://godot_ai_assistant"
const STORE_PATH := ROOT_DIR + "/lint_memory/lint_memory.json"

# Max chars shown for old/new content when formatting "diff" for the prompt.
const MAX_DIFF_CHARS := 6000

var fixes_by_error_key: Dictionary = {} # error_key -> { error_type, error_message, engine_version, fixes:Array }

static func _now_unix() -> int:
	return int(Time.get_unix_time_from_system())

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	if txt.strip_edges().is_empty():
		return null
	var j := JSON.new()
	if j.parse(txt) != OK:
		return null
	return j.data

static func _write_json_atomic(path: String, data: Variant) -> void:
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		DirAccess.make_dir_recursive_absolute(dir_path)
	var tmp_path := "%s.tmp_%d" % [path, Time.get_unix_time_from_system()]
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp_path, path)

static func _pick_error_message(raw_output: String) -> String:
	var txt := str(raw_output)
	for ln in txt.split("\n"):
		var s := ln.strip_edges()
		if not s.is_empty():
			return s
	return txt.strip_edges()

static func _error_type_from_message(msg: String) -> String:
	var m := str(msg).to_lower()
	if m.find("parse") != -1 or m.find("parser") != -1 or m.find("unexpected") != -1:
		return "PARSE_ERROR"
	if m.find("type") != -1 or m.find("cannot convert") != -1:
		return "TYPE_ERROR"
	if m.find("invalid call") != -1 or m.find("nonexistent function") != -1:
		return "INVALID_CALL"
	if m.find("unknown identifier") != -1 or m.find("not declared") != -1:
		return "UNKNOWN_IDENTIFIER"
	return "OTHER"

# Compile-once regex helpers.
static var _re_abs_path: RegEx = null
static var _re_res_path: RegEx = null
static var _re_linecol: RegEx = null
static var _re_quoted: RegEx = null

static func _get_re_abs_path() -> RegEx:
	if _re_abs_path == null:
		var r := RegEx.new()
		r.compile("[A-Za-z]:\\\\[^\\s:]+")
		_re_abs_path = r
	return _re_abs_path

static func _get_re_res_path() -> RegEx:
	if _re_res_path == null:
		var r := RegEx.new()
		r.compile("res://[^\\s:]+")
		_re_res_path = r
	return _re_res_path

static func _get_re_linecol() -> RegEx:
	if _re_linecol == null:
		var r := RegEx.new()
		r.compile("(?:line|Line)\\s*\\d+|\\(\\d+,\\d+\\)|:\\d+:\\d+|:\\d+")
		_re_linecol = r
	return _re_linecol

static func _get_re_quoted() -> RegEx:
	if _re_quoted == null:
		var r := RegEx.new()
		r.compile("'[^']+'|\"[^\"]+\"")
		_re_quoted = r
	return _re_quoted

static func _normalize_signature(raw_output: String) -> String:
	# Replicates the backend's normalization intent:
	# - remove absolute paths, res:// values, line/col, quoted ids, and digit values.
	var sig := _pick_error_message(raw_output)
	var abs_re := _get_re_abs_path()
	var res_re := _get_re_res_path()
	var lc_re := _get_re_linecol()
	var q_re := _get_re_quoted()

	sig = abs_re.sub(sig, "<ABS_PATH>")
	sig = res_re.sub(sig, "<RES_PATH>")
	sig = lc_re.sub(sig, "<LOC>")
	sig = q_re.sub(sig, "<ID>")
	# digits -> <N>
	var digits_re := RegEx.new()
	digits_re.compile("\\d+")
	sig = digits_re.sub(sig, "<N>")
	# whitespace -> single space
	var ws_re := RegEx.new()
	ws_re.compile("\\s+")
	sig = ws_re.sub(sig, " ")
	sig = sig.strip_edges()
	return sig

static func _compute_error_key(engine_version: String, raw_lint_output: String) -> Dictionary:
	var msg := _pick_error_message(raw_lint_output)
	var err_type := _error_type_from_message(msg)
	var sig := _normalize_signature(raw_lint_output)
	var key := "%s|%s" % [str(engine_version), sig]
	return {"key": key, "error_type": err_type, "error_message": msg, "signature": sig}

func load_from_disk() -> void:
	var d := _read_json(STORE_PATH)
	if typeof(d) != TYPE_DICTIONARY:
		fixes_by_error_key = {}
		return
	fixes_by_error_key = d.get("fixes_by_error_key", {}) if d.get("fixes_by_error_key", {}) is Dictionary else {}

func save_to_disk() -> void:
	_write_json_atomic(STORE_PATH, {"fixes_by_error_key": fixes_by_error_key})

static func _trim_for_prompt(s: String, max_chars: int) -> String:
	var t := str(s)
	if t.length() <= max_chars:
		return t
	return t.substr(0, max_chars) + "\n[...truncated...]"

static func _format_old_new_as_diff(old_content: String, new_content: String) -> String:
	# The backend stores a unified diff; client currently keeps the prompt payload concise
	# by showing bounded old/new snippets.
	var old_t := _trim_for_prompt(old_content, MAX_DIFF_CHARS)
	var new_t := _trim_for_prompt(new_content, MAX_DIFF_CHARS)
	return "--- old\n+++ new\n" + old_t + "\n---\n" + new_t

func record_fix(
	engine_version: String,
	file_path: String,
	raw_lint_output: String,
	old_content: String,
	new_content: String,
	explanation: String,
	model: String = ""
) -> Dictionary:
	var computed := _compute_error_key(engine_version, raw_lint_output)
	var key := str(computed.get("key", ""))
	if key.is_empty():
		return {"ok": false, "error": "empty_key"}

	if not fixes_by_error_key.has(key) or typeof(fixes_by_error_key.get(key)) != TYPE_DICTIONARY:
		fixes_by_error_key[key] = {
			"engine_version": engine_version,
			"error_type": str(computed.get("error_type", "")),
			"error_message": str(computed.get("error_message", "")),
			"fixes": [],
		}

	var rec := {
		"id": "%d_%d" % [_now_unix(), randi() % 1000000],
		"created_ts": _now_unix(),
		"file_path": file_path,
		"engine_version": engine_version,
		"explanation": str(explanation),
		"model": str(model),
		"old_content": str(old_content),
		"new_content": str(new_content),
		"diff": _format_old_new_as_diff(str(old_content), str(new_content)),
	}
	var group := fixes_by_error_key.get(key, {}) as Dictionary
	var fixes_arr := group.get("fixes", []) if typeof(group.get("fixes", [])) == TYPE_ARRAY else []
	fixes_arr.push_front(rec)
	group["fixes"] = fixes_arr
	fixes_by_error_key[key] = group
	save_to_disk()

	return {"ok": true, "error_key": key, "fix_id": str(rec.get("id", ""))}

func search_fixes(engine_version: String, raw_lint_output: String, limit: int = 3) -> Array:
	var computed := _compute_error_key(engine_version, raw_lint_output)
	var key := str(computed.get("key", ""))
	if key.is_empty():
		return []
	var group := fixes_by_error_key.get(key, null)
	if typeof(group) != TYPE_DICTIONARY:
		return []
	var fixes_arr: Array = []
	var fixes_variant: Variant = group.get("fixes", null)
	if fixes_variant is Array:
		fixes_arr = fixes_variant
	else:
		return []
	var out: Array = []
	var max_n := max(0, int(limit))
	for i in range(min(fixes_arr.size(), max_n)):
		var f = fixes_arr[i]
		if typeof(f) == TYPE_DICTIONARY:
			out.append(f)
	return out

static func format_fixes_for_prompt(results: Array) -> String:
	if not (results is Array) or results.is_empty():
		return ""
	var parts: Array[String] = []
	parts.append("Past lint fixes (repair memory):")
	var idx := 0
	for r in results:
		idx += 1
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var fix_id := str(r.get("id", idx))
		var file_path := str(r.get("file_path", ""))
		var engine_version := str(r.get("engine_version", ""))
		parts.append("- Fix #" + fix_id + " (file=" + file_path + ", engine=" + engine_version + ")")
		var exp := str(r.get("explanation", "")).strip_edges()
		if not exp.is_empty():
			parts.append("  Explanation: " + exp)
		var diff := str(r.get("diff", "")).strip_edges()
		if not diff.is_empty():
			parts.append("  Diff:")
			parts.append(diff)
	return "\n".join(parts).strip_edges()

