@tool
extends RefCounted
class_name GodotAIEditStore

## Single source of truth for AI edit state: what files/nodes were changed, timeline of
## events, and pending proposals. Persists to user://. Used by:
## - editor/editor_decorator.gd (reads: markers, strip_markers; applies to script/FS/scene trees)
## - ui_tabs/changes_tab.gd (reads: events, pending, get_revert_info; writes: clear_file_status)
## - backend/tool_runner.gd (writes: add_applied_file_change, add_node_change; reads: action icons)
## This file is data/persistence + shared constants; it does not touch the editor UI.
## Editor UI application lives in editor/editor_decorator.gd only.

const STORE_PATH := "user://godot_ai_assistant_edits.json"

## --- Marker constants (used by editor_decorator to label script tabs, FileSystem, Scene tree) ---
const FILE_MARKER_CREATED := "🟢 "   ## New file / just created
const FILE_MARKER_MODIFIED := "🟡 "  ## Modified
const FILE_MARKER_DELETED := "⚫ "   ## Deleted
const FILE_MARKER_FAILED := "🔴 "    ## Lint/edit failed
const NODE_MARKER_CREATED := "🧩 "   ## Component/node just created
const NODE_MARKER_MODIFIED := "🟡 "  ## Node property changed

## All markers (for stripping when re-applying decorations)
const _FILE_MARKERS: Array = ["🟢 ", "🟡 ", "⚫ ", "🔴 "]
const _NODE_MARKERS: Array = ["🧩 ", "🟡 "]

## --- Editor action type constants (unified for chat, timeline, and history) ---
const ACTION_CREATE_FILE := "create_file"
const ACTION_WRITE_FILE := "write_file"
const ACTION_APPEND_TO_FILE := "append_to_file"
const ACTION_APPLY_PATCH := "apply_patch"
const ACTION_CREATE_SCRIPT := "create_script"
const ACTION_DELETE_FILE := "delete_file"
const ACTION_CREATE_NODE := "create_node"
const ACTION_SET_NODE_PROPERTY := "set_node_property"
const ACTION_SET_IMPORT_OPTION := "set_import_option"
const ACTION_RUN_SCENE := "run_scene"
const ACTION_RUN_TERMINAL_COMMAND := "run_terminal_command"
const ACTION_RUN_GODOT_HEADLESS := "run_godot_headless"

## action_type -> { icon: String, label: String }
const _ACTION_DISPLAY: Dictionary = {
	ACTION_CREATE_FILE: {"icon": "📄", "label": "Add file"},
	ACTION_WRITE_FILE: {"icon": "✏️", "label": "Write file"},
	ACTION_APPEND_TO_FILE: {"icon": "➕", "label": "Append"},
	ACTION_APPLY_PATCH: {"icon": "🔧", "label": "Patch"},
	ACTION_CREATE_SCRIPT: {"icon": "📜", "label": "Create script"},
	ACTION_DELETE_FILE: {"icon": "🗑️", "label": "Delete file"},
	ACTION_CREATE_NODE: {"icon": "🧩", "label": "Create component"},
	ACTION_SET_NODE_PROPERTY: {"icon": "⚙️", "label": "Set property"},
	ACTION_SET_IMPORT_OPTION: {"icon": "⚙️", "label": "Set import option"},
	ACTION_RUN_SCENE: {"icon": "▶️", "label": "Run scene"},
	ACTION_RUN_TERMINAL_COMMAND: {"icon": "⌨️", "label": "Run command"},
	ACTION_RUN_GODOT_HEADLESS: {"icon": "▶️", "label": "Run Godot headless"},
}


static func get_action_icon(action_type: String) -> String:
	var d = GodotAIEditStore._ACTION_DISPLAY.get(action_type, {})
	return d.get("icon", "📌") if d is Dictionary else "📌"


static func get_action_label(action_type: String) -> String:
	var d = GodotAIEditStore._ACTION_DISPLAY.get(action_type, {})
	return d.get("label", action_type) if d is Dictionary else str(action_type)


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
	var raw_file_status = d.get("file_status", {})
	file_status = {}
	if raw_file_status is Dictionary:
		for key in raw_file_status.keys():
			file_status[normalize_to_res_path(str(key))] = raw_file_status[key]
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


func add_applied_file_change(change: Dictionary, lint_ok: bool = true, action_type: String = "") -> void:
	# change: { file_path, change_type, old_content, new_content, summary, action_type? }
	var rec := change.duplicate(true)
	rec["lint_ok"] = lint_ok
	if not action_type.is_empty():
		rec["action_type"] = action_type
	_add_event_from_change(rec, false)
	save_to_disk()


func add_node_change(scene_path: String, node_path: String, status: String, summary: String, action_type: String = "") -> void:
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
	if not action_type.is_empty():
		rec["action_type"] = action_type
	events.push_front(rec)
	if not node_status.has(scene_path) or typeof(node_status.get(scene_path)) != TYPE_DICTIONARY:
		node_status[scene_path] = {}
	var per_scene: Dictionary = node_status[scene_path]
	per_scene[node_path] = {"status": status, "last_edit_id": id, "updated_unix": _now_unix()}
	save_to_disk()


func get_file_marker(path: String) -> String:
	var key := normalize_to_res_path(path)
	var st = file_status.get(key, null)
	if typeof(st) != TYPE_DICTIONARY:
		return ""
	match str(st.get("status", "")):
		"created":
			return FILE_MARKER_CREATED
		"modified":
			return FILE_MARKER_MODIFIED
		"deleted":
			return FILE_MARKER_DELETED
		"failed":
			return FILE_MARKER_FAILED
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
			return NODE_MARKER_CREATED
		"modified":
			return NODE_MARKER_MODIFIED
		_:
			return ""


## Normalize path to res:// form so file_status lookups match Script.resource_path and FileSystem metadata.
static func normalize_to_res_path(p: String) -> String:
	var s := str(p).replace("\\", "/").strip_edges()
	if s.is_empty():
		return s
	if s.begins_with("res://"):
		return s
	return "res://" + s


## Like normalize_to_res_path but also converts absolute project path to res:// (for editor UI matching).
static func normalize_for_display_match(p: String) -> String:
	var s := str(p).replace("\\", "/").strip_edges()
	if s.is_empty():
		return s
	if s.begins_with("res://"):
		return s
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	if not project_root.is_empty() and s.begins_with(project_root):
		var suffix := s.substr(project_root.length()).replace("\\", "/").strip_edges(true, false)
		return "res://" + suffix.trim_prefix("/")
	return s


## Strip any known file/node marker from a display string (for re-applying decorations).
static func strip_markers(s: String) -> String:
	var out := s
	for m in _FILE_MARKERS:
		out = out.trim_prefix(m)
	for m in _NODE_MARKERS:
		out = out.trim_prefix(m)
	return out


func _add_event_from_change(change: Dictionary, from_pending: bool) -> void:
	var id := str(change.get("id", ""))
	if id.is_empty():
		id = _new_id()
	var file_path := normalize_to_res_path(str(change.get("file_path", "")))
	var change_type := str(change.get("change_type", "modify"))
	var action_type := str(change.get("action_type", ""))
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
	if not action_type.is_empty():
		ev["action_type"] = action_type
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


## Returns { file_path, old_content } if the event is a file edit that can be reverted; else {}.
## Caller writes old_content to file_path, then call clear_file_status(path) so editor indicators update.
func get_revert_info(edit_id: String) -> Dictionary:
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if str(e.get("id", "")) != edit_id:
			continue
		if str(e.get("kind", "")) != "file":
			return {}
		var old_content := str(e.get("old_content", ""))
		var file_path := normalize_to_res_path(str(e.get("file_path", "")))
		if file_path.is_empty():
			return {}
		return {"file_path": file_path, "old_content": old_content}
	return {}


func clear_file_status(file_path: String) -> void:
	file_status.erase(normalize_to_res_path(file_path))
	save_to_disk()
