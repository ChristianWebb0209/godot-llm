@tool
extends RefCounted
class_name GodotAIRepoIndexStore

## Client-side repo index / structural proximity store.
##
## Goal (phase 1): keep this lightweight and useful without requiring Python-side
## SQLite. We implement:
## - caching extracted `res://...` references per file (outbound dependencies)
## - one-hop related file selection based on those references
##
## Stored under:
## - user://godot_ai_assistant/repo_index/<repo_id>.json

const ROOT_DIR := "user://godot_ai_assistant/repo_index"

# Extensions we consider for indexing.
const INCLUDE_EXTENSIONS := [
	".godot",
	".tscn",
	".tres",
	".res",
	".gd",
	".cs",
	".gdshader",
]

const IGNORE_DIRS := [".git", ".godot", ".import", "Library", "Temp", "obj", "bin"]

var _repo_data: Dictionary = {} # loaded per active repo_id
var _active_repo_id: String = ""

static func _now_unix() -> int:
	return int(Time.get_unix_time_from_system())

static func _safe_repo_id(s: String) -> String:
	var t := str(s).replace("\\", "/").to_lower().strip_edges()
	var out := ""
	for i in range(t.length()):
		var ch := t[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
		else:
			out += "_"
	return out

static func _repo_path(repo_id: String) -> String:
	var rid := str(repo_id).strip_edges()
	if rid.is_empty():
		rid = "unknown"
	return ROOT_DIR + "/" + rid + ".json"

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

static func _extract_res_paths(text: String) -> Array:
	# Simple regex: res:// followed by common Godot path chars.
	# We keep it permissive; the caller can still filter by file existence.
	var re := RegEx.new()
	re.compile("res://[A-Za-z0-9_\\-\\./]+")
	var out: Array = []
	var matches := re.search_all(text)
	for m in matches:
		var s := str(m.get_string())
		if not out.has(s):
			out.append(s)
	return out

# Godot doesn't expose Python's os.path; we re-implement absolute path join using string ops.
static func _join_abs(root_abs: String, rel: String) -> String:
	if root_abs.is_empty():
		return rel
	if rel.is_empty():
		return root_abs
	var r := root_abs.replace("/", "\\").rstrip("\\")
	var p := rel.replace("/", "\\").lstrip("\\")
	return r + "\\" + p

static func _res_to_abs2(project_root_abs: String, res_path: String) -> String:
	var rp := str(res_path).replace("\\", "/").strip_edges()
	if rp.begins_with("res://"):
		rp = rp.substr(6)
	rp = rp.lstrip("/")
	return _join_abs(project_root_abs, rp)

static func _read_file_text_res(res_path: String) -> String:
	if res_path.is_empty():
		return ""
	var root_abs := ProjectSettings.globalize_path("res://")
	var abs_path := _res_to_abs2(root_abs, res_path)
	if abs_path.is_empty() or not FileAccess.file_exists(abs_path):
		return ""
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

func load_repo(project_root_abs: String) -> void:
	var rid := _safe_repo_id(project_root_abs)
	if rid == _active_repo_id and _repo_data.size() > 0:
		return
	_active_repo_id = rid
	var path := _repo_path(rid)
	var d := _read_json(path)
	if typeof(d) != TYPE_DICTIONARY:
		_repo_data = {"indexed_ts": _now_unix(), "files": {}}
	else:
		_repo_data = d

	if typeof(_repo_data.get("files", {})) != TYPE_DICTIONARY:
		_repo_data["files"] = {}

func save_repo() -> void:
	if _active_repo_id.is_empty():
		return
	_write_json_atomic(_repo_path(_active_repo_id), _repo_data)

func _ensure_file_indexed(res_path: String) -> void:
	if res_path.is_empty():
		return
	if _repo_data.get("files", {}) == null or typeof(_repo_data.get("files", {})) != TYPE_DICTIONARY:
		_repo_data["files"] = {}
	var files := _repo_data["files"] as Dictionary
	if files.has(res_path) and typeof(files.get(res_path)) == TYPE_DICTIONARY:
		# Already cached (even if stale); we can extend later with mtime/sha.
		return
	var txt := _read_file_text_res(res_path)
	var deps := _extract_res_paths(txt)
	files[res_path] = {"deps": deps, "indexed_ts": _now_unix()}
	_repo_data["files"] = files
	save_repo()

func get_related_res_paths_one_hop(active_file_res_path: String, max_files: int = 4) -> Array:
	load_repo(ProjectSettings.globalize_path("res://"))
	_ensure_file_indexed(active_file_res_path)

	var files := _repo_data.get("files", {}) if _repo_data.get("files", {}) is Dictionary else {}
	var rec: Dictionary = {} 
	var rec_variant: Variant = files.get(active_file_res_path, null)
	if rec_variant is Dictionary:
		rec = rec_variant
	else:
		return []

	var deps: Array = []
	var deps_variant: Variant = rec.get("deps", null)
	if deps_variant is Array:
		deps = deps_variant
	else:
		return []
	var out: Array = []
	for p in deps:
		if str(p) == active_file_res_path:
			continue
		if not out.has(p):
			out.append(p)
		if out.size() >= max_files:
			break
	return out

