@tool
extends RefCounted
class_name GodotAIAgentStore

## Model/Store: shared chat list state.
##
## Single source of truth for chats + current index. Shared by the dock surface and the
## main-screen surface. Must remain UI-agnostic (no Control/Node references).

signal chats_changed
signal current_chat_changed

## Same structure as dock _chats: [{ id, title, messages, context_usage, prompt_draft, ... }]
var chats: Array = []
var current_index: int = -1


func generate_chat_id() -> String:
	return "c_%d_%d" % [Time.get_ticks_msec(), randi() % 1000000]


func get_chats() -> Array:
	return chats


func get_current_index() -> int:
	return current_index


func set_current_index(i: int) -> void:
	if i == current_index:
		return
	current_index = clampi(i, -1, chats.size() - 1)
	current_chat_changed.emit()


func get_current_chat() -> Dictionary:
	if current_index < 0 or current_index >= chats.size():
		return {}
	return chats[current_index] if typeof(chats[current_index]) == TYPE_DICTIONARY else {}


func set_chats(a: Array) -> void:
	chats = a
	current_index = clampi(current_index, -1, chats.size() - 1)
	chats_changed.emit()
	current_chat_changed.emit()


func ensure_default_chat() -> void:
	if chats.is_empty():
		chats.append(_new_chat_dict("Chat 1"))
		current_index = 0
		chats_changed.emit()
		current_chat_changed.emit()
	elif current_index < 0:
		current_index = 0
		current_chat_changed.emit()


func add_chat() -> int:
	var idx := chats.size() + 1
	var title := "Chat %d" % idx
	chats.append(_new_chat_dict(title))
	current_index = chats.size() - 1
	chats_changed.emit()
	current_chat_changed.emit()
	return current_index


func remove_chat_at(idx: int) -> void:
	if idx < 0 or idx >= chats.size():
		return
	var was_current := (idx == current_index)
	chats.remove_at(idx)
	if chats.is_empty():
		current_index = -1
	else:
		if was_current:
			current_index = mini(idx, chats.size() - 1)
		elif idx < current_index:
			current_index -= 1
	chats_changed.emit()
	current_chat_changed.emit()


func _new_chat_dict(title: String) -> Dictionary:
	return {
		"id": generate_chat_id(),
		"title": title,
		"messages": [],
		"context_usage": {},
		"prompt_draft": "",
		"current_activity": {},
		"activity_history": [],
		"pinned_context": [],
	}
