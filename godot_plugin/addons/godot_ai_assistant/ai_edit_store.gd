@tool
extends RefCounted
class_name GodotAIEditStore

const STORE_PATH := "user://godot_ai_assistant_edits.json"

## file_status: path -> { status, last_edit_id, updated_unix }
var file_status: Dictionary = {}

## node_status: scene_path -> { node_path -> { status, last_edit_id, updated_unix } }
var node_status: Dictionary = {}

## events: newest-first
var events: Array = []

## pending: newest-first proposals; each item contains old/new content, not applied yet.
var pending: Array = []


func load_from_disk() -> void:
	if not FileAccess.file_exists(STORE_PATH):
		return
	var f := FileAccess.open(STORE_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	if txt.strip_edges().is_empty():
		return
	var j := JSON.new()
	if j.parse(txt) != OK:
		return
	if typeof(j.data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = j.data
	file_status = d.get("file_status", {}) if d.get("file_status", {}) is Dictionary else {}
	node_status = d.get("node_status", {}) if d.get("node_status", {}) is Dictionary else {}
	events = d.get("events", []) if d.get("events", []) is Array else []
	pending = d.get("pending", []) if d.get("pending", []) is Array else []


func save_to_disk() -> void:
	var d := {
		"file_status": file_status,
		"node_status": node_status,
		"events": events,
		"pending": pending,
	}
	var f := FileAccess.open(STORE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(d))
	f.close()


func _now_unix() -> int:
	return int(Time.get_unix_time_from_system())


func _new_id() -> String:
	# Stable-enough unique id without requiring Crypto.
	return "%d-%d" % [Time.get_unix_time_from_system(), randi() % 1000000000]


func add_pending_file_change(change: Dictionary) -> String:
	# change: { file_path, change_type, old_content, new_content, summary, lint_status? }
	var id := _new_id()
	var rec := change.duplicate(true)
	rec["id"] = id
	rec["created_unix"] = _now_unix()
	rec["kind"] = "file"
	pending.push_front(rec)
	save_to_disk()
	return id


func accept_pending(id: String) -> Dictionary:
	for i in range(pending.size()):
		var p = pending[i]
		if typeof(p) == TYPE_DICTIONARY and str(p.get("id", "")) == id:
			pending.remove_at(i)
			_add_event_from_change(p, true)
			save_to_disk()
			return p
	return {}


func reject_pending(id: String) -> Dictionary:
	for i in range(pending.size()):
		var p = pending[i]
		if typeof(p) == TYPE_DICTIONARY and str(p.get("id", "")) == id:
			pending.remove_at(i)
			save_to_disk()
			return p
	return {}


func add_applied_file_change(change: Dictionary, lint_ok: bool = true) -> void:
	# change: { file_path, change_type, old_content, new_content, summary }
	var rec := change.duplicate(true)
	rec["lint_ok"] = lint_ok
	_add_event_from_change(rec, false)
	save_to_disk()


func add_node_change(scene_path: String, node_path: String, status: String, summary: String) -> void:
	var id := _new_id()
	var rec := {
		"id": id,
		"created_unix": _now_unix(),
		"kind": "node",
		"scene_path": scene_path,
		"node_path": node_path,
		"status": status,
		"summary": summary,
	}
	events.push_front(rec)
	if not node_status.has(scene_path) or typeof(node_status.get(scene_path)) != TYPE_DICTIONARY:
		node_status[scene_path] = {}
	var per_scene: Dictionary = node_status[scene_path]
	per_scene[node_path] = {"status": status, "last_edit_id": id, "updated_unix": _now_unix()}
	save_to_disk()


func get_file_marker(path: String) -> String:
	var st = file_status.get(path, null)
	if typeof(st) != TYPE_DICTIONARY:
		return ""
	match str(st.get("status", "")):
		"created":
			return "🟢 "
		"modified":
			return "🟡 "
		"deleted":
			return "⚫ "
		"failed":
			return "🔴 "
		_:
			return ""


func get_node_marker(scene_path: String, node_path: String) -> String:
	var per_scene := node_status.get(scene_path, null)
	if typeof(per_scene) != TYPE_DICTIONARY:
		return ""
	var st = per_scene.get(node_path, null)
	if typeof(st) != TYPE_DICTIONARY:
		return ""
	match str(st.get("status", "")):
		"created":
			return "🟢 "
		"modified":
			return "🟡 "
		_:
			return ""


func _add_event_from_change(change: Dictionary, from_pending: bool) -> void:
	var id := str(change.get("id", ""))
	if id.is_empty():
		id = _new_id()
	var file_path := str(change.get("file_path", ""))
	var change_type := str(change.get("change_type", "modify"))
	var lint_ok := bool(change.get("lint_ok", true))
	var summary := str(change.get("summary", ""))
	if summary.is_empty():
		summary = "%s %s" % [change_type, file_path]
	var ev := {
		"id": id,
		"created_unix": int(change.get("created_unix", _now_unix())),
		"kind": "file",
		"file_path": file_path,
		"change_type": change_type,
		"summary": summary,
		"old_content": str(change.get("old_content", "")),
		"new_content": str(change.get("new_content", "")),
		"from_pending": from_pending,
		"lint_ok": lint_ok,
	}
	events.push_front(ev)
	var status := "modified"
	if change_type == "create":
		status = "created"
	if change_type == "delete":
		status = "deleted"
	if not lint_ok:
		status = "failed"
	file_status[file_path] = {
		"status": status,
		"last_edit_id": id,
		"updated_unix": _now_unix(),
	}
