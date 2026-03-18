@tool
extends RefCounted
class_name GodotAIChatStorage

## Local chat persistence under user://godot_ai_assistant/chats.
## Schema (per LOCAL_FIRST plan):
## - user://godot_ai_assistant/chats/index.json
##     { chats: [{ id, title, created_unix, updated_unix, turn_count }], current_chat_id }
## - user://godot_ai_assistant/chats/<chat_id>/chat.json
##     { id, title, created_unix, updated_unix, tags, pinned_context }
## - user://godot_ai_assistant/chats/<chat_id>/turns/<turn_id>.json
##     { id, created_unix, role, text, request, response }

const ROOT_DIR := "user://godot_ai_assistant"
const CHATS_DIR := ROOT_DIR + "/chats"
const INDEX_PATH := CHATS_DIR + "/index.json"


static func _ensure_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		DirAccess.make_dir_recursive_absolute(path)


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
	DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp_path, path)


static func load_index() -> Dictionary:
	var data := _read_json(INDEX_PATH)
	if typeof(data) != TYPE_DICTIONARY:
		return {
			"chats": [],
			"current_chat_id": "",
		}
	return {
		"chats": data.get("chats", []) if data.get("chats", []) is Array else [],
		"current_chat_id": str(data.get("current_chat_id", "")),
	}


static func save_index(index: Dictionary) -> void:
	var out := {
		"chats": index.get("chats", []) if index.get("chats", []) is Array else [],
		"current_chat_id": str(index.get("current_chat_id", "")),
	}
	_write_json_atomic(INDEX_PATH, out)


static func _chat_dir(chat_id: String) -> String:
	return "%s/%s" % [CHATS_DIR, chat_id]


static func _chat_meta_path(chat_id: String) -> String:
	return "%s/chat.json" % _chat_dir(chat_id)


static func _turns_dir(chat_id: String) -> String:
	return "%s/turns" % _chat_dir(chat_id)


static func load_chat_metadata(chat_id: String) -> Dictionary:
	var data := _read_json(_chat_meta_path(chat_id))
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data


static func save_chat_metadata(chat_id: String, meta: Dictionary) -> void:
	_ensure_dir(_chat_dir(chat_id))
	var now := int(Time.get_unix_time_from_system())
	var out := meta.duplicate(true)
	if not out.has("id"):
		out["id"] = chat_id
	if not out.has("created_unix"):
		out["created_unix"] = now
	out["updated_unix"] = now
	_write_json_atomic(_chat_meta_path(chat_id), out)


static func list_turn_ids(chat_id: String) -> Array:
	var base := _turns_dir(chat_id)
	var dir := DirAccess.open(base)
	if dir == null:
		return []
	var out: Array = []
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if dir.current_is_dir():
			continue
		if not name.ends_with(".json"):
			continue
		out.append(name.trim_suffix(".json"))
	dir.list_dir_end()
	out.sort()
	return out


static func load_turn(chat_id: String, turn_id: String) -> Dictionary:
	var path := "%s/%s.json" % [_turns_dir(chat_id), turn_id]
	var data := _read_json(path)
	return data if typeof(data) == TYPE_DICTIONARY else {}


static func append_turn(chat_id: String, turn: Dictionary) -> String:
	_ensure_dir(_turns_dir(chat_id))
	var now := int(Time.get_unix_time_from_system())
	var id := str(turn.get("id", ""))
	if id.is_empty():
		id = "%d_%d" % [now, randi() % 1000000]
	var rec := turn.duplicate(true)
	rec["id"] = id
	if not rec.has("created_unix"):
		rec["created_unix"] = now
	var path := "%s/%s.json" % [_turns_dir(chat_id), id]
	_write_json_atomic(path, rec)
	return id


static func delete_chat(chat_id: String) -> void:
	var dir_path := _chat_dir(chat_id)
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	# Recursive delete
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if name == "." or name == "..":
			continue
		var child := dir_path.path_join(name)
		if dir.current_is_dir():
			DirAccess.remove_absolute(child) # best-effort; small tree
		else:
			DirAccess.remove_absolute(child)
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)


static func search_turns(chat_id: String, query: String, max_results: int = 100) -> Array:
	var q := query.strip_edges()
	if q.is_empty():
		return []
	var ids := list_turn_ids(chat_id)
	var out: Array = []
	for turn_id in ids:
		if out.size() >= max_results:
			break
		var rec := load_turn(chat_id, turn_id)
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var text := str(rec.get("text", ""))
		if text.findn(q) != -1:
			out.append(rec)
	return out

