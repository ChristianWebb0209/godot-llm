@tool
extends RefCounted
class_name GodotAIChatRenderer

## Chat rendering: render log to BBCode, escape bbcode, scroll, tool_calls UI.

const SCROLL_AT_BOTTOM_THRESHOLD := 25.0
var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


static func escape_bbcode(t: String) -> String:
	return t.replace("[", "[[")


func scroll_output_to_bottom() -> void:
	## Deferred smooth scroll so layout (fit_content) has updated max_value first.
	_dock.call_deferred("_deferred_smooth_scroll_chat_to_bottom")


func scroll_output_to_bottom_instant() -> void:
	if _dock.chat_scroll:
		var vbar: VScrollBar = _dock.chat_scroll.get_v_scroll_bar()
		if vbar != null:
			vbar.value = vbar.max_value
		return
	if _dock.output_text_edit:
		_dock.output_text_edit.scroll_to_line(max(_dock.output_text_edit.get_line_count() - 1, 0))


## Last RichTextLabel body for an assistant message block (for typewriter updates without full rebuild).
func find_last_assistant_richtext() -> RichTextLabel:
	if _dock.chat_message_list == null:
		return null
	var n: int = _dock.chat_message_list.get_child_count()
	for i in range(n - 1, -1, -1):
		var v: Node = _dock.chat_message_list.get_child(i)
		if v.has_meta("_ai_chat_role") and str(v.get_meta("_ai_chat_role")) == "assistant":
			for c in v.get_children():
				if c is RichTextLabel:
					return c as RichTextLabel
	return null


func is_output_at_bottom() -> bool:
	if _dock.chat_scroll:
		var vbar: VScrollBar = _dock.chat_scroll.get_v_scroll_bar()
		if vbar == null:
			return true
		return (vbar.max_value - vbar.value) <= SCROLL_AT_BOTTOM_THRESHOLD
	if not _dock.output_text_edit:
		return true
	var vbar: VScrollBar = _dock.output_text_edit.get_v_scroll_bar()
	if vbar == null:
		return true
	return (vbar.max_value - vbar.value) <= SCROLL_AT_BOTTOM_THRESHOLD


func render_chat_log() -> void:
	_dock.ensure_chat_has_messages()
	# Never clear or overwrite when chat index is invalid so messages never disappear.
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return
	if _dock.chat_message_list == null:
		_fallback_render_to_richtext()
		return
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
	# Clear and rebuild message blocks so chat is one continuous scrollable stream.
	for c in _dock.chat_message_list.get_children():
		c.queue_free()
	var font_size := 18
	if _dock._settings:
		font_size = _dock._settings.text_size
	elif _dock.output_text_edit:
		font_size = int(_dock.output_text_edit.get_theme_font_size("normal_font_size"))
	if font_size <= 0:
		font_size = 18
	var idx := 0
	for msg in messages:
		if msg.get("hidden", false):
			idx += 1
			continue
		var role: String = msg.get("role", "assistant")
		var text: String = msg.get("text", "")
		var is_last := idx == messages.size() - 1
		var is_streaming_assistant := (
			_dock.is_streaming_in_progress() and is_last and role == "assistant"
		)
		var use_typewriter_plain: bool = _dock.should_typewriter_assistant_at_index(idx)
		if use_typewriter_plain and role == "assistant":
			text = _dock.get_typewriter_plain_slice(text)
			is_streaming_assistant = _dock.is_streaming_in_progress() and is_last
		var act_raw = msg.get("activity_history", [])
		var activity_history: Array = act_raw if typeof(act_raw) == TYPE_ARRAY else []
		var tc_raw = msg.get("tool_calls_summary", [])
		var tool_calls_summary: Array = tc_raw if typeof(tc_raw) == TYPE_ARRAY else []
		var block := _make_message_block(
			role, text, is_streaming_assistant, activity_history, tool_calls_summary, font_size, use_typewriter_plain
		)
		if block != null:
			_dock.chat_message_list.add_child(block)
		idx += 1
	# Current activity is shown at bottom of chat (Thinking... / Tool call: X + elapsed).
	_dock.set_inline_activity_label(null)
	var cur_act: Dictionary = _dock.get_current_activity()
	if cur_act.size() > 0:
		var act_vbox := VBoxContainer.new()
		act_vbox.add_theme_constant_override("separation", 4)
		var act_label := Label.new()
		var raw: String = cur_act.get("text", "")
		act_label.text = raw + "   …"
		act_label.add_theme_font_size_override("font_size", font_size)
		act_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.6, 1.0))
		act_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		act_vbox.add_child(act_label)
		_dock.chat_message_list.add_child(act_vbox)
		_dock.set_inline_activity_label(act_label)
	scroll_output_to_bottom()
	return


func _make_message_block(
	role: String, text: String, is_streaming: bool,
	activity_history: Array, tool_calls_summary: Array, font_size: int, use_plain_typewriter: bool = false
) -> Control:
	var vbox := VBoxContainer.new()
	vbox.set_meta("_ai_chat_role", role)
	vbox.add_theme_constant_override("separation", 4)
	# Role label
	var role_label := Label.new()
	role_label.text = "You" if role == "user" else "Assistant"
	role_label.add_theme_font_size_override("font_size", font_size)
	role_label.add_theme_color_override("font_color", Color(0.69, 0.69, 0.69, 1.0))
	if role == "user":
		role_label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95, 1.0))
	vbox.add_child(role_label)
	# Message text
	var content := RichTextLabel.new()
	content.bbcode_enabled = true
	content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.scroll_active = false
	content.fit_content = true
	content.custom_minimum_size.y = 0
	content.add_theme_font_size_override("normal_font_size", font_size)
	content.add_theme_font_size_override("mono_font_size", font_size)
	if role == "user":
		content.text = "[color=#e0e0e0][right]" + escape_bbcode(text) + "[/right][/color]"
	else:
		var assistant_bb: String
		if use_plain_typewriter:
			assistant_bb = escape_bbcode(text)
		else:
			assistant_bb = _dock.get_markdown_renderer().markdown_to_bbcode(text)
		var cursor_bb := "[color=#c0c0c0]▌[/color]" if is_streaming else ""
		content.text = "[color=#e0e0e0]" + assistant_bb + cursor_bb + "[/color]"
	vbox.add_child(content)
	# Inline dropdowns for assistant: Thought history and Tool calls (in chat at the right place)
	if role == "assistant" and (activity_history.size() > 0 or tool_calls_summary.size() > 0):
		var dropdown_row := HBoxContainer.new()
		dropdown_row.add_theme_constant_override("separation", 8)
		var thought_list: VBoxContainer = null
		var tool_list: VBoxContainer = null
		if activity_history.size() > 0:
			var thought_btn := Button.new()
			thought_btn.text = "Thought history (%d) ▶" % activity_history.size()
			thought_btn.flat = true
			thought_btn.add_theme_font_size_override("font_size", 12)
			thought_btn.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
			thought_list = VBoxContainer.new()
			thought_list.visible = false
			for h in activity_history:
				var l := Label.new()
				var elapsed: float = float(h.get("ended_at", 0) - h.get("started_at", 0))
				var elapsed_str := GodotAIActivityState.format_elapsed(elapsed)
				l.text = "  %s   %s" % [str(h.get("text", "")), elapsed_str]
				l.add_theme_font_size_override("font_size", 12)
				l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
				thought_list.add_child(l)
			thought_btn.pressed.connect(func():
				thought_list.visible = not thought_list.visible
				var s := " ▼" if thought_list.visible else " ▶"
				thought_btn.text = "Thought history (%d)" % activity_history.size() + s
			)
			dropdown_row.add_child(thought_btn)
		if tool_calls_summary.size() > 0:
			var tool_btn := Button.new()
			tool_btn.text = "Tool calls (%d) ▶" % tool_calls_summary.size()
			tool_btn.flat = true
			tool_btn.add_theme_font_size_override("font_size", 12)
			tool_btn.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
			tool_list = VBoxContainer.new()
			tool_list.visible = false
			for j in range(tool_calls_summary.size()):
				var line: String = str(tool_calls_summary[j]) if j < tool_calls_summary.size() else ""
				var l := Label.new()
				l.text = "  %d. %s" % [j + 1, line]
				l.add_theme_font_size_override("font_size", 12)
				l.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				tool_list.add_child(l)
			tool_btn.pressed.connect(func():
				tool_list.visible = not tool_list.visible
				var s2 := " ▼" if tool_list.visible else " ▶"
				tool_btn.text = "Tool calls (%d)" % tool_calls_summary.size() + s2
			)
			dropdown_row.add_child(tool_btn)
		vbox.add_child(dropdown_row)
		if thought_list != null:
			vbox.add_child(thought_list)
		if tool_list != null:
			vbox.add_child(tool_list)
	# Divider
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	vbox.add_child(sep)
	return vbox


func _fallback_render_to_richtext() -> void:
	if not _dock.output_text_edit:
		return
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
	var parts: Array[String] = []
	var width := int(_dock.output_text_edit.size.x)
	var font_size := int(_dock.output_text_edit.get_theme_font_size("normal_font_size"))
	if font_size <= 0:
		font_size = 18
	var approx_char_px := max(6.0, float(font_size) * 0.60)
	var chars_fit := int(float(width) / approx_char_px) if width > 0 else 40
	var divider_chars := clampi(max(24, min(chars_fit, 200)), 24, 200)
	var divider := "─".repeat(divider_chars)
	var idx := 0
	for msg in messages:
		if msg.get("hidden", false):
			idx += 1
			continue
		var role: String = msg.get("role", "assistant")
		var text: String = msg.get("text", "")
		var is_last := idx == messages.size() - 1
		var is_streaming_assistant := (
			_dock.is_streaming_in_progress() and is_last and role == "assistant"
		)
		if role == "user":
			var user_bb := "[color=#b0b0b0][b]You[/b][/color]\n[color=#e0e0e0][right]" + escape_bbcode(text)
			user_bb += "[/right][/color]"
			parts.append(user_bb)
		else:
			var assistant_bb := _dock.get_markdown_renderer().markdown_to_bbcode(text)
			var cursor_bb := "[color=#c0c0c0]▌[/color]" if is_streaming_assistant else ""
			var asst_bb := "[color=#b0b0b0][b]Assistant[/b][/color]\n[color=#e0e0e0]"
			asst_bb += assistant_bb + cursor_bb + "[/color]"
			parts.append(asst_bb)
		parts.append("[color=#44485588]" + divider + "[/color]\n")
		idx += 1
	var bbcode: String = "\n".join(parts)
	var was_at_bottom: bool = is_output_at_bottom()
	_dock.output_text_edit.clear()
	_dock.output_text_edit.text = bbcode
	if was_at_bottom:
		scroll_output_to_bottom()


func update_tool_calls_ui() -> void:
	# When using inline message list, tool/thought dropdowns are in-chat; hide global buttons.
	if _dock.chat_message_list != null:
		if _dock.tool_calls_button:
			_dock.tool_calls_button.visible = false
		if _dock.thought_history_button:
			_dock.thought_history_button.visible = false
		return
	if not _dock.tool_calls_button or not _dock.tool_calls_list:
		return
	var summaries: Array = []
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		var messages: Array = _dock.get_chats()[_dock.get_current_chat()].get("messages", [])
		for i in range(messages.size() - 1, -1, -1):
			var msg = messages[i]
			if typeof(msg) == TYPE_DICTIONARY and msg.get("role", "") == "assistant":
				summaries = msg.get("tool_calls_summary", [])
				break
	if summaries.is_empty():
		_dock.tool_calls_button.visible = false
		_dock.tool_calls_list.visible = false
		return
	_dock.tool_calls_button.visible = true
	for c in _dock.tool_calls_list.get_children():
		c.queue_free()
	for j in range(summaries.size()):
		var line: String = str(summaries[j]) if j < summaries.size() else ""
		var l := Label.new()
		l.text = "  %d. %s" % [j + 1, line]
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_dock.tool_calls_list.add_child(l)
	_dock.tool_calls_list.visible = false
	update_tool_calls_button_label()


func update_tool_calls_button_label() -> void:
	if not _dock.tool_calls_button:
		return
	var n := 0
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		var messages: Array = _dock.get_chats()[_dock.get_current_chat()].get("messages", [])
		for i in range(messages.size() - 1, -1, -1):
			var msg = messages[i]
			if typeof(msg) == TYPE_DICTIONARY and msg.get("role", "") == "assistant":
				var summary: Array = msg.get("tool_calls_summary", [])
				if summary.size() > 0:
					n = summary.size()
					break
	var vis := _dock.tool_calls_list and _dock.tool_calls_list.visible
	_dock.tool_calls_button.text = "Tool calls (%d)" % n + (" ▼" if vis else " ▶")
