@tool
extends RefCounted
class_name GodotAIChatState

## Chat state: ensure default chat, ensure messages, tab switch/reorder.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func ensure_default_chat() -> void:
	if _dock.chat_tab_bar == null:
		return
	if _dock.get_chats().is_empty():
		var title := "Chat 1"
		_dock.get_chats().append({
			"id": _dock.generate_chat_id(),
			"title": title,
			"messages": [],
			"context_usage": {},
			"prompt_draft": "",
			"current_activity": {},
			"activity_history": [],
			"pinned_context": [],
		})
		_dock.chat_tab_bar.clear_tabs()
		_dock.chat_tab_bar.add_tab(title)
		_dock.set_current_chat_index(0)
		_dock.chat_tab_bar.current_tab = 0


func ensure_chat_has_messages() -> void:
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return
	var chat: Dictionary = _dock.get_chats()[_dock.get_current_chat()]
	if not chat.has("prompt_draft"):
		chat["prompt_draft"] = ""
	if not chat.has("current_activity"):
		chat["current_activity"] = {}
	if not chat.has("activity_history"):
		chat["activity_history"] = []
	if not chat.has("messages"):
		var transcript: String = chat.get("transcript", "")
		chat["messages"] = []
		if transcript.strip_edges().length() > 0:
			chat["messages"].append({"role": "assistant", "text": transcript})
		chat.erase("transcript")
	if not chat.has("context_usage"):
		chat["context_usage"] = {}
	if not chat.has("pinned_context"):
		chat["pinned_context"] = []
	if not chat.has("id") or (chat.get("id", "") as String).is_empty():
		chat["id"] = _dock.generate_chat_id()


func on_new_chat_pressed() -> void:
	if _dock.chat_tab_bar == null:
		return
	var idx := _dock.get_chats().size() + 1
	var title := "Chat %d" % idx
	_dock.get_chats().append({
		"id": _dock.generate_chat_id(),
		"title": title,
		"messages": [],
		"context_usage": {},
		"prompt_draft": "",
		"current_activity": {},
		"activity_history": [],
		"pinned_context": [],
	})
	_dock.chat_tab_bar.add_tab(title)
	_dock.set_current_chat_index(_dock.get_chats().size() - 1)
	_dock.chat_tab_bar.current_tab = _dock.get_current_chat()


func on_chat_tab_selected(tab_index: int) -> void:
	if tab_index < 0 or tab_index >= _dock.get_chats().size():
		return
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		var cur: Dictionary = _dock.get_chats()[_dock.get_current_chat()]
		if not cur.has("prompt_draft"):
			cur["prompt_draft"] = ""
		cur["prompt_draft"] = _dock.prompt_text_edit.text if _dock.prompt_text_edit else ""
		cur["current_activity"] = _dock.get_current_activity().duplicate()
		cur["activity_history"] = _dock.get_activity_history().duplicate()
	_dock.set_current_chat_index(tab_index)
	ensure_chat_has_messages()
	var chat: Dictionary = _dock.get_chats()[tab_index]
	if _dock.prompt_text_edit:
		_dock.prompt_text_edit.text = chat.get("prompt_draft", "")
	_dock.set_current_activity_dict((chat.get("current_activity", {}) as Dictionary).duplicate())
	_dock.set_activity_history_arr((chat.get("activity_history", []) as Array).duplicate())
	var messages: Array = chat.get("messages", [])
	_dock.set_streamed_markdown("")
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		_dock.set_streamed_markdown(messages[messages.size() - 1].get("text", ""))
	# So Send/Stop reflects the newly selected chat (e.g. Send on new chat even if another is streaming).
	_dock._update_ask_button_state()


func on_chat_tab_rearranged(_idx_to: int) -> void:
	if _dock.chat_tab_bar == null or _dock.get_chats().size() != _dock.chat_tab_bar.tab_count:
		return
	var new_chats: Array = []
	for i in range(_dock.chat_tab_bar.tab_count):
		var title := _dock.chat_tab_bar.get_tab_title(i)
		for c in _dock.get_chats():
			if typeof(c) == TYPE_DICTIONARY and str(c.get("title", "")) == title:
				new_chats.append(c)
				break
	if new_chats.size() == _dock.get_chats().size():
		_dock.set_chats_arr(new_chats)
		_dock.set_current_chat_index(_dock.chat_tab_bar.current_tab)
