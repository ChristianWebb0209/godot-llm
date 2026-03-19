@tool
extends RefCounted

## Controller helper: keeps `ai_dock.gd`'s `_ready()` wiring out of the file.
## This intentionally mirrors the original `_ready()` behavior.

var _dock

func _init(dock) -> void:
	_dock = dock


func run_ready() -> void:
	print("AI Assistant: _ready called on dock")

	# Use the layout from the scene; let Godot's dock system drive our size.
	_dock.focus_mode = Control.FOCUS_ALL

	# Auto-focus prompt when user clicks onto the dock or switches to Chat tab.
	_dock.focus_entered.connect(func() -> void:
		if _dock._chat_ux == null:
			_dock._chat_ux = GodotAIChatUX.new(_dock)
		_dock._chat_ux.on_dock_focus_entered()
	)

	if _dock.tab_container:
		_dock.tab_container.focus_entered.connect(func() -> void:
			if _dock._chat_ux == null:
				_dock._chat_ux = GodotAIChatUX.new(_dock)
			_dock._chat_ux.on_dock_focus_entered()
		)
		_dock.tab_container.focus_exited.connect(func() -> void:
			if _dock._chat_ux == null:
				_dock._chat_ux = GodotAIChatUX.new(_dock)
			_dock._chat_ux.on_dock_focus_exited()
		)

	if _dock._typewriter_timer == null:
		_dock._typewriter_timer = Timer.new()
		_dock._typewriter_timer.wait_time = 0.028
		_dock._typewriter_timer.timeout.connect(_dock._on_typewriter_timer_timeout)
		_dock.add_child(_dock._typewriter_timer)

	_dock.output_text_edit = _dock.get_node_or_null("TabContainer/Chat/VBox/IOContainer/OutputText") as RichTextLabel
	_dock.status_label = _dock.get_node_or_null("TabContainer/Chat/VBox/BottomRow/StatusLabel") as Label

	if _dock._dock_tabs_controller:
		_dock._dock_tabs_controller.resolve_settings_controls()

	if _dock.output_text_edit:
		_dock.output_text_edit.bbcode_enabled = true
		if _dock.output_text_edit.resized.is_connected(_dock._chat_renderer.render_chat_log) == false:
			_dock.output_text_edit.resized.connect(_dock._chat_renderer.render_chat_log)

	if _dock.ask_button:
		_dock.ask_button.text = ""
		_dock.ask_button.flat = false
		_dock.ask_button.custom_minimum_size = Vector2(32, 32)
		_dock.ask_button.pressed.connect(_dock._chat_streaming.on_ask_pressed)
		_dock._chat_ux.update_ask_button_state()
	else:
		print("AI Assistant: ask_button is null")

	if _dock.prompt_text_edit:
		# Keep the input a fixed single-row height; let long placeholder/text overflow horizontally.
		_dock.prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
		_dock.prompt_text_edit.scroll_fit_content_height = false
		_dock.prompt_text_edit.scroll_past_end_of_file = false
		_dock.prompt_text_edit.gui_input.connect(func(event: InputEvent) -> void:
			if _dock._chat_ux == null:
				_dock._chat_ux = GodotAIChatUX.new(_dock)
			_dock._chat_ux.on_prompt_text_edit_gui_input(event)
		)
		_dock.prompt_text_edit.text_changed.connect(_dock._chat_ux.update_ask_button_state)

	if _dock.http_request:
		_dock.http_request.request_completed.connect(_dock._http_handler.on_http_request_completed)
	else:
		print("AI Assistant: http_request is null")

	if _dock.new_chat_button:
		_dock.new_chat_button.pressed.connect(_dock._on_new_chat_pressed)

	if _dock.chat_tab_bar:
		_dock.chat_tab_bar.drag_to_rearrange_enabled = true
		_dock.chat_tab_bar.tab_selected.connect(_dock._on_chat_tab_selected)
		if _dock.chat_tab_bar.has_signal("active_tab_rearranged"):
			_dock.chat_tab_bar.active_tab_rearranged.connect(_dock._on_chat_tab_rearranged)
		if _dock.chat_tab_bar.has_signal("tab_close_pressed"):
			_dock.chat_tab_bar.tab_close_pressed.connect(_dock._chat_state.on_chat_tab_close_pressed)
		if _dock._editor_chrome == null:
			_dock._editor_chrome = GodotAIEditorChrome.new(_dock)
		_dock._editor_chrome.apply_chat_tab_bar_editor_style()

	if _dock.tab_container:
		if _dock._dock_tabs_controller:
			_dock._dock_tabs_controller.connect_main_tabs(_dock.tab_container)

		# Enable drag-to-reorder on main tabs (Chat, History, Settings)
		var main_tab_bar: TabBar = _dock.tab_container.get_tab_bar()
		if main_tab_bar:
			main_tab_bar.drag_to_rearrange_enabled = true

		# Clear, readable tab labels; Settings is furthest right by default (tab order in scene)
		if _dock.tab_container.get_tab_count() >= 3:
			_dock.tab_container.set_tab_title(0, "Chat")
			_dock.tab_container.set_tab_title(1, "History")
			_dock.tab_container.set_tab_title(2, "Settings")

	if _dock._dock_tabs_controller:
		_dock._dock_tabs_controller.wire_settings_signals()
		_dock._dock_tabs_controller.wire_changes_signals()

	if _dock.thought_history_button:
		_dock.thought_history_button.pressed.connect(_dock._on_thought_history_toggled)
	if _dock.tool_calls_button:
		_dock.tool_calls_button.pressed.connect(_dock._on_tool_calls_toggled)

	# Activity (Thinking... / Tool call: X) is shown inline at bottom of chat, not at top.
	if _dock.current_activity_label:
		_dock.current_activity_label.visible = false

	if _dock.context_viewer_button:
		_dock.context_viewer_button.pressed.connect(_dock._on_context_viewer_button_pressed)

	if _dock.chat_scroll and _dock.chat_message_list:
		_dock.chat_scroll.resized.connect(_dock._update_chat_message_list_min_width)
		_dock.call_deferred("_update_chat_message_list_min_width")
		_dock.chat_message_list.add_theme_constant_override("separation", 12)
		_dock.chat_scroll.gui_input.connect(_dock._chat_context_menu_ctrl.on_chat_gui_input)
		var vbar: VScrollBar = _dock.chat_scroll.get_v_scroll_bar()
		if vbar != null:
			vbar.value_changed.connect(_dock._on_chat_scroll_value_changed)

	_dock._chat_context_menu = PopupMenu.new()
	_dock._chat_context_menu.id_pressed.connect(_dock._chat_context_menu_ctrl.on_menu_id_pressed)
	_dock.add_child(_dock._chat_context_menu)

	_dock._export_file_dialog = EditorFileDialog.new()
	_dock._export_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_dock._export_file_dialog.add_filter("Text file (*.txt)", "*.txt")
	_dock._export_file_dialog.add_filter("Markdown (*.md)", "*.md")
	_dock._export_file_dialog.title = "Export chat"
	_dock._export_file_dialog.file_selected.connect(_dock._chat_context_menu_ctrl.export_chat_to_path)
	_dock.add_child(_dock._export_file_dialog)

	if _dock._settings_tab:
		_dock._settings_tab.apply_settings_from_config()
		_dock._chat_ux.update_context_usage_label()
	if _dock._chat_state:
		_dock._chat_state.ensure_default_chat()
		_dock._chat_state.update_chat_tab_close_visibility()
		_dock._refresh_pinned_context_row()
	if _dock._settings_tab:
		_dock._settings_tab.refresh_settings_tab_from_config()

	if _dock._http_handler == null:
		_dock._http_handler = GodotAIHttpRequestHandler.new(_dock)
		_dock._http_handler.start_health_check()

	if _dock._changes_tab:
		_dock._changes_tab.render_changes_tab()

	if _dock._editor_chrome == null:
		_dock._editor_chrome = GodotAIEditorChrome.new(_dock)
		_dock._editor_chrome.start_decoration_refresh()

	# Deferred so editor docks (FileSystem, Script, Scene) are built; then retry once after a short delay.
	_dock.call_deferred("_apply_editor_decorations")
	var late_timer := Timer.new()
	late_timer.wait_time = 0.6
	late_timer.one_shot = true
	late_timer.timeout.connect(_dock._apply_editor_decorations)
	_dock.add_child(late_timer)
	late_timer.start()

