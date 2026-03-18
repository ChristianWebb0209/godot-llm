@tool
extends RefCounted
class_name GodotAIChatUX

## Controller: chat UX (scroll-follow, typewriter reveal, ask-panel animation, small UI updates).

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func on_prompt_text_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE and _dock._streaming_in_progress and _dock._streaming_chat_index == _dock.get_current_chat():
			if _dock.prompt_text_edit:
				_dock.prompt_text_edit.accept_event()
			_dock._stream_generation += 1
			_dock._streaming_in_progress = false
			_dock._streaming_chat_index = -1
			update_ask_button_state()
			_dock._activity_state.clear_activity()
			on_interject_stopped()
			return
		if key.keycode in [KEY_ENTER, KEY_KP_ENTER] and not key.shift_pressed:
			if _dock.prompt_text_edit:
				_dock.prompt_text_edit.accept_event()
			_dock._on_ask_button_pressed()


func on_interject_stopped() -> void:
	_dock.set_status("Stopped. Type a quick fix or follow-up above and press Enter.")
	if _dock.prompt_text_edit and is_instance_valid(_dock.prompt_text_edit):
		_dock.call_deferred("_focus_prompt_for_interject")


func focus_prompt_input() -> void:
	if _dock.prompt_text_edit and is_instance_valid(_dock.prompt_text_edit):
		_dock.prompt_text_edit.grab_focus()


func on_dock_focus_entered() -> void:
	if _dock.tab_container and _dock.tab_container.current_tab >= 0 and _dock.tab_container.current_tab < _dock.tab_container.get_child_count():
		var child: Node = _dock.tab_container.get_child(_dock.tab_container.current_tab)
		if child and child.name == "Chat":
			_dock.call_deferred("_focus_prompt_input")


func on_dock_focus_exited() -> void:
	_dock.call_deferred("_check_unfocus_after_focus_exited")


func check_unfocus_after_focus_exited() -> void:
	if _dock._selected_timeline_id.is_empty():
		return
	var owner: Control = _dock.get_viewport().gui_get_focus_owner() as Control
	if owner != null and _dock.is_ancestor_of(owner):
		return
	_dock.unfocus_timeline_edit()


func on_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE and _dock._streaming_in_progress and _dock._streaming_chat_index == _dock.get_current_chat():
			_dock._stream_generation += 1
			_dock._streaming_in_progress = false
			_dock._streaming_chat_index = -1
			update_ask_button_state()
			_dock._activity_state.clear_activity()
			on_interject_stopped()
			_dock.get_viewport().set_input_as_handled()


func update_ask_button_state() -> void:
	if not _dock.ask_button:
		return
	var prompt_empty: bool = _dock.prompt_text_edit == null or _dock.prompt_text_edit.text.strip_edges().is_empty()
	if _dock._streaming_in_progress and _dock._streaming_chat_index == _dock.get_current_chat():
		_dock.ask_button.text = "Stop"
		_dock.ask_button.icon = null
		_dock.ask_button.disabled = false
	elif _dock._streaming_in_progress:
		_dock.ask_button.text = ""
		_dock.ask_button.icon = _dock._ask_icon_idle if _dock._ask_icon_idle else null
		_dock.ask_button.disabled = false
	else:
		_dock.ask_button.text = ""
		_dock.ask_button.icon = _dock._ask_icon_idle if _dock._ask_icon_idle else null
		_dock.ask_button.disabled = prompt_empty


func update_chat_message_list_min_width() -> void:
	if not _dock.chat_scroll or not _dock.chat_message_list:
		return
	var w := _dock.chat_scroll.size.x
	if w > 0:
		_dock.chat_message_list.custom_minimum_size.x = w


func update_context_usage_label() -> void:
	if not _dock.context_usage_bar:
		return
	var usage: Dictionary = {}
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		usage = _dock.get_chats()[_dock.get_current_chat()].get("context_usage", {})
	if usage.is_empty():
		_dock.context_usage_bar.show_percentage = false
		_dock.context_usage_bar.indeterminate = true
		_dock.context_usage_bar.tooltip_text = "Context: unknown"
		return
	var est := int(usage.get("estimated_prompt_tokens", 0))
	var limit := int(usage.get("limit_tokens", 0))
	var pct := float(usage.get("percent", 0.0))
	_dock.context_usage_bar.indeterminate = false
	_dock.context_usage_bar.max_value = 1.0
	_dock.context_usage_bar.value = clampf(pct, 0.0, 1.0)
	if limit > 0:
		_dock.context_usage_bar.tooltip_text = "Context: %d%% (%d / %d tokens)" % [int(pct * 100.0), est, limit]
	else:
		_dock.context_usage_bar.tooltip_text = "Context: %d tokens" % est


func scroll_output_to_bottom() -> void:
	if _dock._chat_session_store:
		_dock._chat_session_store.user_scrolled_away = false
	else:
		_dock._user_scrolled_away = false
	_dock._chat_renderer.scroll_output_to_bottom()


func scroll_output_to_bottom_if_following() -> void:
	if (_dock._chat_session_store.user_scrolled_away if _dock._chat_session_store else _dock._user_scrolled_away):
		return
	_dock._chat_renderer.scroll_output_to_bottom()


func on_chat_scroll_value_changed() -> void:
	if (_dock._chat_session_store.scroll_was_programmatic if _dock._chat_session_store else _dock._scroll_was_programmatic):
		return
	if not _dock._chat_renderer.is_output_at_bottom():
		if _dock._chat_session_store:
			_dock._chat_session_store.user_scrolled_away = true
		else:
			_dock._user_scrolled_away = true


func deferred_smooth_scroll_chat_to_bottom() -> void:
	await _dock.get_tree().process_frame
	await _dock.get_tree().process_frame
	if _dock.chat_scroll == null:
		return
	var vbar: VScrollBar = _dock.chat_scroll.get_v_scroll_bar()
	if vbar == null:
		return
	var target: float = vbar.max_value
	if target <= 0.0:
		return
	if _dock._chat_scroll_tween != null:
		_dock._chat_scroll_tween.kill()
		_dock._chat_scroll_tween = null
	if abs(vbar.value - target) < 3.0:
		vbar.value = target
		return
	if _dock._chat_session_store:
		_dock._chat_session_store.scroll_was_programmatic = true
	else:
		_dock._scroll_was_programmatic = true
	_dock._chat_scroll_tween = _dock.create_tween()
	_dock._chat_scroll_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_dock._chat_scroll_tween.tween_property(vbar, "value", target, 0.28)
	_dock._chat_scroll_tween.tween_callback(func() -> void:
		if _dock._chat_session_store:
			_dock._chat_session_store.scroll_was_programmatic = false
		else:
			_dock._scroll_was_programmatic = false
	)


func animate_ask_panel_in(panel: Control) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	if _dock._chat_session_store:
		_dock._chat_session_store.user_scrolled_away = false
	else:
		_dock._user_scrolled_away = false
	panel.pivot_offset = Vector2(0, 0)
	panel.scale = Vector2(1.0, 0.0)
	var tween := panel.create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(panel, "scale", Vector2(1.0, 1.0), 0.28)
	var flow: Control = panel.get_meta("_ai_ask_flow") if panel.has_meta("_ai_ask_flow") else null
	if flow != null:
		var delay := 0.08
		for i in range(flow.get_child_count()):
			var btn: Control = flow.get_child(i) as Control
			if btn != null:
				btn.modulate.a = 0.0
				tween.tween_interval(delay)
				tween.tween_property(btn, "modulate:a", 1.0, 0.15)
	tween.tween_callback(func() -> void:
		_dock.call_deferred("_deferred_smooth_scroll_chat_to_bottom")
	)


func should_typewriter_assistant_at_index(idx: int) -> bool:
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return false
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()].get("messages", [])
	if idx < 0 or idx >= messages.size():
		return false
	if str(messages[idx].get("role", "")) != "assistant":
		return false
	if idx != messages.size() - 1:
		return false
	var full: String = str(messages[idx].get("text", ""))
	var reasoning: String = str(messages[idx].get("reasoning", ""))
	var total_len: int = reasoning.length() + full.length()
	if total_len == 0:
		return false
	var streaming_here := _dock._streaming_in_progress and _dock._streaming_chat_index == _dock.get_current_chat()
	if streaming_here:
		return true
	return _dock._tw_active_chat_index == _dock.get_current_chat() and _dock._tw_visible < total_len


func get_typewriter_reasoning_slice(reasoning: String) -> String:
	return reasoning.substr(0, mini(_dock._tw_visible, reasoning.length()))


func get_typewriter_plain_slice(full_text: String, reasoning_length: int = 0) -> String:
	var start_at: int = mini(maxi(0, _dock._tw_visible - reasoning_length), full_text.length())
	return full_text.substr(0, start_at)


func on_typewriter_timer_timeout() -> void:
	if _dock._typewriter_timer == null:
		return
	var chat_i := _dock._streaming_chat_index if (_dock._streaming_in_progress and _dock._streaming_chat_index >= 0) else _dock._tw_active_chat_index
	if chat_i < 0 or chat_i >= _dock.get_chats().size():
		_dock._typewriter_timer.stop()
		return
	var messages: Array = _dock.get_chats()[chat_i].get("messages", [])
	if messages.is_empty():
		_dock._typewriter_timer.stop()
		return
	var last_idx := messages.size() - 1
	var last: Variant = messages[last_idx]
	if typeof(last) != TYPE_DICTIONARY or str(last.get("role", "")) != "assistant":
		_dock._typewriter_timer.stop()
		return
	var full: String = str(last.get("text", ""))
	var reasoning: String = str(last.get("reasoning", ""))
	var total_len: int = reasoning.length() + full.length()
	var streaming_here := _dock._streaming_in_progress and _dock._streaming_chat_index >= 0
	if total_len == 0:
		return
	_dock._tw_visible = mini(_dock._tw_visible + _dock._TYPEWRITER_CHARS_PER_TICK, total_len)
	if chat_i == _dock.get_current_chat():
		_dock._chat_renderer.render_chat_log()
		scroll_output_to_bottom_if_following()
	if not streaming_here and _dock._tw_visible >= total_len:
		_dock._typewriter_timer.stop()
		_dock._tw_active_chat_index = -1
		if chat_i == _dock.get_current_chat():
			_dock._chat_renderer.render_chat_log()
			scroll_output_to_bottom_if_following()

