@tool
extends RefCounted
class_name GodotAIChatRenderer

## Chat rendering: render log to BBCode, escape bbcode, scroll, tool_calls UI.

const SCROLL_AT_BOTTOM_THRESHOLD := 40.0
var _dock: GodotAIDock
const _MESSAGE_BLOCK_SCENE := preload("res://addons/godot_ai_assistant/ui/components/chat_message_block.tscn")

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func get_message_list_target() -> Control:
	return _dock.chat_message_list


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
	var target_list: Control = get_message_list_target()
	if target_list == null:
		_fallback_render_to_richtext()
		return
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
	# Incremental render: only rebuild if message count (visible) changed.
	var visible_msgs: Array = []
	for m in messages:
		if typeof(m) == TYPE_DICTIONARY and (m as Dictionary).get("hidden", false):
			continue
		visible_msgs.append(m)
	var font_size := 18
	if _dock._settings:
		font_size = _dock._settings.text_size
	elif _dock.output_text_edit:
		font_size = int(_dock.output_text_edit.get_theme_font_size("normal_font_size"))
	if font_size <= 0:
		font_size = 18
	var desired_count := visible_msgs.size()
	var existing_blocks := 0
	for child in target_list.get_children():
		if child is GodotAIChatMessageBlock:
			existing_blocks += 1
	if existing_blocks != desired_count:
		for c in target_list.get_children():
			c.queue_free()

	var idx := 0
	for msg in visible_msgs:
		var d: Dictionary = msg if typeof(msg) == TYPE_DICTIONARY else {}
		var role: String = d.get("role", "assistant")
		var text: String = d.get("text", "")
		var reasoning: String = d.get("reasoning", "")
		var is_last := idx == visible_msgs.size() - 1
		var is_streaming_assistant := (
			_dock.is_streaming_in_progress() and is_last and role == "assistant"
		)
		var use_typewriter_plain: bool = _dock.should_typewriter_assistant_at_index(idx)
		if use_typewriter_plain and role == "assistant":
			text = _dock.get_typewriter_plain_slice(text, reasoning.length())
			is_streaming_assistant = _dock.is_streaming_in_progress() and is_last
		var act_raw = d.get("activity_history", [])
		var activity_history: Array = act_raw if typeof(act_raw) == TYPE_ARRAY else []
		var tc_raw = d.get("tool_calls_summary", [])
		var tool_calls_summary: Array = tc_raw if typeof(tc_raw) == TYPE_ARRAY else []
		var block: GodotAIChatMessageBlock = null
		if idx < target_list.get_child_count() and target_list.get_child(idx) is GodotAIChatMessageBlock:
			block = target_list.get_child(idx) as GodotAIChatMessageBlock
		else:
			block = (_MESSAGE_BLOCK_SCENE.instantiate() as GodotAIChatMessageBlock)
			target_list.add_child(block)
		if block:
			var user_bb := "[color=#e0e0e0][right]" + escape_bbcode(text) + "[/right][/color]"
			var resolved: Dictionary = {"display_text": text, "has_options": false, "options": []}
			if role != "user":
				resolved = GodotAIAskResolver.resolve(text)
			var display_text: String = resolved.get("display_text", text) if resolved.get("has_options", false) else text
			var assistant_bb: String = escape_bbcode(display_text) if use_typewriter_plain else _dock.get_markdown_renderer().markdown_to_bbcode(display_text)
			var cursor_bb := "[color=#c0c0c0]|[/color]" if is_streaming_assistant else ""
			var msg_bb := user_bb if role == "user" else ("[color=#e0e0e0]" + assistant_bb + cursor_bb + "[/color]")
			var reasoning_bb := ""
			if role == "assistant" and not reasoning.is_empty():
				var reasoning_slice: String = _dock.get_typewriter_reasoning_slice(reasoning) if use_typewriter_plain else reasoning
				if not reasoning_slice.is_empty():
					reasoning_bb = "[color=#b8c7bf]" + _dock.get_markdown_renderer().markdown_to_bbcode(reasoning_slice) + "[/color]"
			block.configure(idx, role, msg_bb, reasoning_bb, font_size, true)
		idx += 1
	# Current activity is shown at bottom of chat (Thinking... / Tool call: X + elapsed).
	_dock.set_inline_activity_label(null)
	var cur_act: Dictionary = _dock.get_current_activity()
	if cur_act.size() > 0:
		var act_vbox := VBoxContainer.new()
		act_vbox.add_theme_constant_override("separation", 4)
		act_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var act_label := Label.new()
		var raw: String = cur_act.get("text", "")
		act_label.text = raw + "   ..."
		act_label.add_theme_font_size_override("font_size", font_size)
		act_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.6, 1.0))
		act_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		act_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		act_vbox.add_child(act_label)
		target_list.add_child(act_vbox)
		_dock.set_inline_activity_label(act_label)
	_dock._chat_ux.scroll_output_to_bottom_if_following()
	return


func _make_ask_feedback_panel(options: Array, font_size: int) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.18, 0.16, 0.95)
	style.border_width_left = 2
	style.border_width_top = 0
	style.border_width_right = 0
	style.border_width_bottom = 0
	style.border_color = Color(0.35, 0.5, 0.45, 0.9)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	style.set_content_margin_individual(14, 12, 14, 12)
	panel.add_theme_stylebox_override("panel", style)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(margin)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 10)
	margin.add_child(inner)
	var prompt_label := Label.new()
	prompt_label.text = "Choose an option:"
	prompt_label.add_theme_font_size_override("font_size", font_size - 2)
	prompt_label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.7, 1.0))
	prompt_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(prompt_label)
	var flow := FlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 6)
	inner.add_child(flow)
	for opt in options:
		var opt_text: String = str(opt).strip_edges()
		if opt_text.is_empty():
			continue
		var btn := Button.new()
		btn.text = opt_text
		btn.flat = true
		btn.add_theme_font_size_override("font_size", font_size - 2)
		btn.custom_minimum_size.x = 0
		var btn_style := StyleBoxFlat.new()
		btn_style.bg_color = Color(0.22, 0.28, 0.26, 0.9)
		btn_style.border_width_left = 1
		btn_style.border_width_top = 1
		btn_style.border_width_right = 1
		btn_style.border_width_bottom = 1
		btn_style.border_color = Color(0.4, 0.5, 0.45, 0.8)
		btn_style.set_corner_radius_all(4)
		btn_style.set_content_margin_all(8)
		btn.add_theme_stylebox_override("normal", btn_style)
		var hover_style: StyleBoxFlat = btn_style.duplicate()
		hover_style.bg_color = Color(0.28, 0.36, 0.32, 0.95)
		btn.add_theme_stylebox_override("hover", hover_style)
		btn.add_theme_color_override("font_color", Color(0.85, 0.9, 0.88, 1.0))
		var captured := opt_text
		btn.pressed.connect(func() -> void:
			if _dock != null and is_instance_valid(_dock):
				_dock.send_user_message(captured)
		)
		flow.add_child(btn)
	panel.set_meta("_ai_ask_flow", flow)
	return panel


func _make_message_block(
	role: String, text: String, is_streaming: bool,
	activity_history: Array, tool_calls_summary: Array, font_size: int, use_plain_typewriter: bool = false,
	reasoning: String = ""
) -> Control:
	var vbox := VBoxContainer.new()
	vbox.set_meta("_ai_chat_role", role)
	vbox.add_theme_constant_override("separation", 4)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Role label
	var role_label := Label.new()
	role_label.text = "You" if role == "user" else "Assistant"
	role_label.add_theme_font_size_override("font_size", font_size)
	role_label.add_theme_color_override("font_color", Color(0.69, 0.69, 0.69, 1.0))
	if role == "user":
		role_label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95, 1.0))
	role_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(role_label)
	# Thinking (reasoning) block for assistant - Cursor-style: opaque box, narrow text, typewriter, max height + scroll
	if role == "assistant" and not reasoning.is_empty():
		var reasoning_slice: String = _dock.get_typewriter_reasoning_slice(reasoning) if use_plain_typewriter else reasoning
		if not reasoning_slice.is_empty():
			var think_panel := PanelContainer.new()
			think_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.12, 0.14, 0.13, 0.92)
			style.border_width_left = 2
			style.border_width_top = 0
			style.border_width_right = 0
			style.border_width_bottom = 0
			style.border_color = Color(0.35, 0.45, 0.4, 0.8)
			style.set_corner_radius_all(4)
			style.set_content_margin_all(10)
			style.set_content_margin_individual(14, 10, 14, 10)
			think_panel.add_theme_stylebox_override("panel", style)
			var think_scroll := ScrollContainer.new()
			think_scroll.custom_minimum_size.y = 0
			think_scroll.custom_maximum_size.y = 160
			think_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			think_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			think_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			var think_content := RichTextLabel.new()
			think_content.bbcode_enabled = true
			think_content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			think_content.fit_content = true
			think_content.custom_minimum_size.y = 0
			think_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			think_content.selection_enabled = true
			think_content.context_menu_enabled = true
			think_content.add_theme_font_size_override("normal_font_size", font_size - 2)
			think_content.add_theme_font_size_override("mono_font_size", font_size - 2)
			think_content.add_theme_color_override("default_color", Color(0.72, 0.78, 0.75, 1.0))
			think_content.text = "[color=#b8c7bf]" + _dock.get_markdown_renderer().markdown_to_bbcode(reasoning_slice) + "[/color]"
			think_content.resized.connect(func():
				var bar: VScrollBar = think_scroll.get_v_scroll_bar()
				if bar != null:
					think_scroll.scroll_vertical = int(bar.max_value)
			)
			think_scroll.add_child(think_content)
			think_panel.add_child(think_scroll)
			vbox.add_child(think_panel)
	# Message text (for assistant: resolve __OPTIONS__ block so we can show clickable choices when not streaming)
	var resolved: Dictionary = {"display_text": "", "options": [], "has_options": false}
	var content := RichTextLabel.new()
	content.bbcode_enabled = true
	content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.scroll_active = false
	content.fit_content = true
	content.custom_minimum_size.y = 0
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.selection_enabled = true
	content.context_menu_enabled = true
	content.add_theme_font_size_override("normal_font_size", font_size)
	content.add_theme_font_size_override("mono_font_size", font_size)
	if role == "user":
		content.text = "[color=#e0e0e0][right]" + escape_bbcode(text) + "[/right][/color]"
	else:
		var resolve_result: Dictionary = GodotAIAskResolver.resolve(text)
		resolved = resolve_result
		var display_text: String = resolve_result.get("display_text", text) if resolve_result.get("has_options", false) else text
		var assistant_bb: String
		if use_plain_typewriter:
			assistant_bb = escape_bbcode(display_text)
		else:
			assistant_bb = _dock.get_markdown_renderer().markdown_to_bbcode(display_text)
		var cursor_bb := "[color=#c0c0c0]|[/color]" if is_streaming else ""
		content.text = "[color=#e0e0e0]" + assistant_bb + cursor_bb + "[/color]"
	vbox.add_child(content)
	# Assistant "ask with options": styled panel that unrolls and shows choice buttons
	if role == "assistant" and not is_streaming and resolved.get("has_options", false):
		var options: Array = resolved.get("options", [])
		if options.size() > 0:
			var ask_panel := _make_ask_feedback_panel(options, font_size)
			if ask_panel != null:
				vbox.add_child(ask_panel)
				_dock.call_deferred("_animate_ask_panel_in", ask_panel)
	# Inline for assistant: Thought history (dropdown) and Tool calls (inline list, no second label)
	if role == "assistant" and (activity_history.size() > 0 or tool_calls_summary.size() > 0):
		var dropdown_row := HBoxContainer.new()
		dropdown_row.add_theme_constant_override("separation", 8)
		dropdown_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var thought_list: VBoxContainer = null
		if activity_history.size() > 0:
			var thought_btn := Button.new()
			thought_btn.text = "Thought history (%d) >" % activity_history.size()
			thought_btn.flat = true
			thought_btn.add_theme_font_size_override("font_size", 12)
			thought_btn.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
			thought_list = VBoxContainer.new()
			thought_list.visible = false
			thought_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			for h in activity_history:
				var l := Label.new()
				var elapsed: float = float(h.get("ended_at", 0) - h.get("started_at", 0))
				var elapsed_str := GodotAIActivityState.format_elapsed(elapsed)
				l.text = "  %s   %s" % [str(h.get("text", "")), elapsed_str]
				l.add_theme_font_size_override("font_size", 12)
				l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				thought_list.add_child(l)
			thought_btn.pressed.connect(func():
				thought_list.visible = not thought_list.visible
				var s := " v" if thought_list.visible else " >"
				thought_btn.text = "Thought history (%d)" % activity_history.size() + s
			)
			dropdown_row.add_child(thought_btn)
		if dropdown_row.get_child_count() > 0:
			vbox.add_child(dropdown_row)
		if thought_list != null:
			vbox.add_child(thought_list)
		# Tool calls: inline list below the message (no separate "Tool calls" label)
		if tool_calls_summary.size() > 0:
			var tool_list := VBoxContainer.new()
			tool_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tool_list.add_theme_constant_override("separation", 2)
			for j in range(tool_calls_summary.size()):
				var line: String = str(tool_calls_summary[j]) if j < tool_calls_summary.size() else ""
				var l := Label.new()
				l.text = "  %d. %s" % [j + 1, line]
				l.add_theme_font_size_override("font_size", 12)
				l.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				tool_list.add_child(l)
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
	var divider := "-".repeat(divider_chars)
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
			var resolved_fb := GodotAIAskResolver.resolve(text)
			var display_fb: String = resolved_fb.get("display_text", text) if resolved_fb.get("has_options", false) else text
			var assistant_bb := _dock.get_markdown_renderer().markdown_to_bbcode(display_fb)
			var cursor_bb := "[color=#c0c0c0]|[/color]" if is_streaming_assistant else ""
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
		_dock._chat_ux.scroll_output_to_bottom_if_following()


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
	_dock.tool_calls_button.text = "Tool calls (%d)" % n + (" v" if vis else " >")
