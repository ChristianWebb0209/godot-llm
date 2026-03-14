@tool
extends Control
class_name GodotAIDock

const _LOG_PREFIX := "[AI Assistant] "

@onready var tab_container: TabContainer = $TabContainer
@onready var chat_tab_bar: TabBar = $TabContainer/Chat/VBox/ChatTabBarRow/ChatTabBar
@onready var context_usage_label: Label = $TabContainer/Chat/VBox/ChatTabBarRow/ContextUsageLabel
@onready var new_chat_button: Button = $TabContainer/Chat/VBox/ChatTabBarRow/NewChatButton
@onready var current_activity_label: Label = $TabContainer/Chat/VBox/ActivityBlock/CurrentActivityLabel
@onready var thought_history_button: Button = $TabContainer/Chat/VBox/ActivityBlock/ThoughtHistoryButton
@onready var thought_history_list: VBoxContainer = $TabContainer/Chat/VBox/ActivityBlock/ThoughtHistoryList
@onready var tool_calls_button: Button = $TabContainer/Chat/VBox/ActivityBlock/ToolCallsButton
@onready var tool_calls_list: VBoxContainer = $TabContainer/Chat/VBox/ActivityBlock/ToolCallsList
@onready var output_text_edit: RichTextLabel = $TabContainer/Chat/VBox/IOContainer/OutputText
@onready var prompt_text_edit: TextEdit = $TabContainer/Chat/VBox/IOContainer/PromptTextEdit
@onready var model_option: OptionButton = $TabContainer/Chat/VBox/BottomRow/ToolRow/ModelOption
@onready var ask_button: Button = $TabContainer/Chat/VBox/BottomRow/ToolRow/AskButton
@onready var copy_button: Button = $TabContainer/Chat/VBox/BottomRow/ToolRow/CopyButton
@onready var follow_agent_check: CheckButton = $TabContainer/Chat/VBox/BottomRow/ToolRow/FollowAgentCheck
@onready var allow_editor_actions_check: CheckButton = $TabContainer/Chat/VBox/BottomRow/ToolRow/AllowEditorActionsCheck
var status_label: Label = null  # Optional: StatusLabel removed from UI
@onready var http_request: HTTPRequest = $HTTPRequest
@onready var history_refresh_button: Button = $TabContainer/History/Margin/HistoryVBox/HistoryTopRow/HistoryRefreshButton
@onready var history_list: ItemList = $TabContainer/History/Margin/HistoryVBox/HistorySplit/HistoryList
@onready var history_detail_label: RichTextLabel = $TabContainer/History/Margin/HistoryVBox/HistorySplit/HistoryDetailVBox/HistoryDetailLabel
@onready var history_undo_button: Button = $TabContainer/History/Margin/HistoryVBox/HistorySplit/HistoryDetailVBox/HistoryUndoButton
@onready var settings_text_size_spin: SpinBox = $TabContainer/Settings/Margin/Scroll/SettingsVBox/DisplaySection/TextSizeRow/SettingsTextSizeSpin
@onready var settings_word_wrap_check: CheckButton = $TabContainer/Settings/Margin/Scroll/SettingsVBox/DisplaySection/SettingsWordWrapCheck
@onready var settings_rag_url_edit: LineEdit = $TabContainer/Settings/Margin/Scroll/SettingsVBox/AISection/RagUrlRow/SettingsRagUrlEdit
@onready var settings_api_key_edit: LineEdit = $TabContainer/Settings/Margin/Scroll/SettingsVBox/AISection/ApiKeyRow/SettingsApiKeyEdit
@onready var settings_base_url_edit: LineEdit = $TabContainer/Settings/Margin/Scroll/SettingsVBox/AISection/BaseUrlRow/SettingsBaseUrlEdit
@onready var settings_model_option: OptionButton = $TabContainer/Settings/Margin/Scroll/SettingsVBox/AISection/SettingsModelRow/SettingsModelOption
@onready var settings_save_button: Button = $TabContainer/Settings/Margin/Scroll/SettingsVBox/SettingsButtons/SettingsSaveButton
@onready var refresh_indicators_button: Button = $TabContainer/Settings/Margin/Scroll/SettingsVBox/SettingsButtons/RefreshIndicatorsButton
@onready var indexing_content: Label = $TabContainer/Settings/Margin/Scroll/SettingsVBox/IndexingSection/IndexingContent
@onready var context_windows_list: VBoxContainer = $TabContainer/Settings/Margin/Scroll/SettingsVBox/ContextSection/ContextWindowsList
@onready var index_status_request: HTTPRequest = $IndexStatusRequest

@onready var pending_list: ItemList = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/PendingList
@onready var pending_accept_button: Button = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/PendingButtonsRow/PendingAcceptButton
@onready var pending_reject_button: Button = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/PendingButtonsRow/PendingRejectButton
@onready var timeline_list: ItemList = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/TimelineList
@onready var diff_old_text: TextEdit = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/RightVBox/DiffSplit/OldText
@onready var diff_new_text: TextEdit = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/RightVBox/DiffSplit/NewText

var _markdown_renderer := GodotAIMarkdownRenderer.new()
var _streaming_in_progress: bool = false
var _streamed_markdown: String = ""

var rag_service_url: String = "http://127.0.0.1:8000"
var _pending_http_kind: StringName = &""

var _editor_interface: EditorInterface = null
var _tool_executor: GodotAIEditorToolExecutor = null
var _settings: GodotAISettings = null
var _edit_store: GodotAIEditStore = null
var _decorator: GodotAIEditorDecorator = null
var _history_events: Array = []
var _selected_history_edit_id: int = -1
var _ask_icon_idle: Texture2D = null
var _ask_icon_busy: Texture2D = null
var _selected_pending_id: String = ""
var _selected_timeline_id: String = ""
var _last_tool_prompt: String = ""
var _last_tool_trigger: String = "tool_action"
var _decoration_timer: Timer = null

# Each chat: { title, messages, context_usage, prompt_draft, current_activity, activity_history }
# prompt_draft = unsent text in prompt box; current_activity/activity_history = status (Thinking, etc.)
var _chats: Array = []
var _current_chat: int = -1
const _SCROLL_AT_BOTTOM_THRESHOLD: float = 25.0

# Current chat's activity (synced with _chats[i] when switching tabs)
var _current_activity: Dictionary = {}  # { "text": String, "started_at": float }
var _activity_history: Array = []  # [ { "text": String, "started_at": float, "ended_at": float }, ... ]
var _activity_glow_tween: Tween = null


func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e
	_tool_executor = GodotAIEditorToolExecutor.new(e) if e else null
	_settings = GodotAISettings.new()
	_settings.set_editor_interface(e)
	_edit_store = GodotAIEditStore.new()
	_edit_store.load_from_disk()
	_decorator = GodotAIEditorDecorator.new(e, _edit_store)
	if _editor_interface:
		var base := _editor_interface.get_base_control()
		if base:
			_ask_icon_idle = base.get_theme_icon("Play", "EditorIcons")
			_ask_icon_busy = base.get_theme_icon("Reload", "EditorIcons")


func _set_status(t: String) -> void:
	if status_label:
		status_label.text = t


func _ready() -> void:
	print("AI Assistant: _ready called on dock")
	status_label = get_node_or_null("TabContainer/Chat/VBox/BottomRow/StatusLabel") as Label
	if output_text_edit:
		output_text_edit.bbcode_enabled = true
		if output_text_edit.resized.is_connected(_render_chat_log) == false:
			output_text_edit.resized.connect(_render_chat_log)
	if ask_button:
		ask_button.text = ""
		ask_button.flat = false
		ask_button.custom_minimum_size = Vector2(32, 32)
		ask_button.pressed.connect(_on_ask_button_pressed)
		_update_ask_button_state()
	else:
		print("AI Assistant: ask_button is null")
	if prompt_text_edit:
		prompt_text_edit.gui_input.connect(_on_prompt_text_edit_gui_input)

	if copy_button:
		copy_button.pressed.connect(_on_copy_button_pressed)
	else:
		print("AI Assistant: copy_button is null")

	if http_request:
		http_request.request_completed.connect(_on_http_request_completed)
	else:
		print("AI Assistant: http_request is null")

	if new_chat_button:
		new_chat_button.pressed.connect(_on_new_chat_pressed)
	if chat_tab_bar:
		chat_tab_bar.drag_to_rearrange_enabled = true
		chat_tab_bar.tab_selected.connect(_on_chat_tab_selected)
		if chat_tab_bar.has_signal("active_tab_rearranged"):
			chat_tab_bar.active_tab_rearranged.connect(_on_chat_tab_rearranged)
	if model_option:
		model_option.item_selected.connect(_on_model_selected)
	if follow_agent_check:
		follow_agent_check.toggled.connect(_on_follow_agent_toggled)
	if allow_editor_actions_check:
		allow_editor_actions_check.toggled.connect(_on_allow_editor_actions_toggled)
	if tab_container:
		tab_container.tab_changed.connect(_on_main_tab_changed)
		# Enable drag-to-reorder on main tabs (Chat, Edit History, Settings, Pending & Timeline)
		var main_tab_bar: TabBar = tab_container.get_tab_bar()
		if main_tab_bar:
			main_tab_bar.drag_to_rearrange_enabled = true
		# Clear, readable tab labels (usability: users see purpose at a glance)
		if tab_container.get_tab_count() >= 4:
			tab_container.set_tab_title(0, "Chat")
			tab_container.set_tab_title(1, "Edit History")
			tab_container.set_tab_title(2, "Settings")
			tab_container.set_tab_title(3, "Pending & Timeline")
	if settings_save_button:
		settings_save_button.pressed.connect(_on_settings_save_pressed)
	if index_status_request:
		index_status_request.request_completed.connect(_on_index_status_request_completed)
	if refresh_indicators_button:
		refresh_indicators_button.pressed.connect(_on_refresh_indicators_pressed)
	if history_refresh_button:
		history_refresh_button.pressed.connect(_on_history_refresh_pressed)
	if history_list:
		history_list.item_selected.connect(_on_history_item_selected)
	if history_undo_button:
		history_undo_button.pressed.connect(_on_history_undo_pressed)

	if pending_list:
		pending_list.item_selected.connect(_on_pending_item_selected)
	if pending_accept_button:
		pending_accept_button.text = "Revert selected"
		pending_accept_button.pressed.connect(_on_revert_selected_pressed)
	if pending_reject_button:
		pending_reject_button.visible = false
	if timeline_list:
		timeline_list.item_selected.connect(_on_timeline_item_selected)
	if thought_history_button:
		thought_history_button.pressed.connect(_on_thought_history_toggled)
	if tool_calls_button:
		tool_calls_button.pressed.connect(_on_tool_calls_toggled)

	_apply_settings_from_config()
	_update_context_usage_label()
	_ensure_default_chat()
	_refresh_settings_tab_from_config()
	_start_health_check()
	_render_changes_tab()
	_start_decoration_refresh()
	# Deferred so editor docks (FileSystem, Script, Scene) are built; then retry once after a short delay.
	call_deferred("_apply_editor_decorations")
	var late_timer := Timer.new()
	late_timer.wait_time = 0.6
	late_timer.one_shot = true
	late_timer.timeout.connect(_apply_editor_decorations)
	add_child(late_timer)
	late_timer.start()


func _start_decoration_refresh() -> void:
	# The editor UI can rebuild trees/tabs; refresh markers periodically.
	if _decoration_timer != null:
		return
	_decoration_timer = Timer.new()
	_decoration_timer.wait_time = 1.0
	_decoration_timer.one_shot = false
	_decoration_timer.autostart = true
	add_child(_decoration_timer)
	_decoration_timer.timeout.connect(_on_decoration_timer_timeout)


func _on_decoration_timer_timeout() -> void:
	# Only do work if we have anything to show.
	if _edit_store == null:
		return
	if _edit_store.file_status.is_empty() and _edit_store.node_status.is_empty():
		return
	_apply_editor_decorations()


func _on_prompt_text_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode in [KEY_ENTER, KEY_KP_ENTER] and not key.shift_pressed:
			if prompt_text_edit:
				prompt_text_edit.accept_event()
			_on_ask_button_pressed()


func _on_ask_button_pressed() -> void:
	print("AI Assistant: Ask button pressed")
	_ensure_default_chat()
	var question: String = prompt_text_edit.text.strip_edges()
	if question.is_empty():
		_set_status("Please enter a question.")
		return

	# Remember the originating prompt so any subsequent tool-driven edits can be logged server-side.
	_last_tool_prompt = question
	_last_tool_trigger = "tool_action"

	# Add user and placeholder assistant messages first, then render so user sees their message instantly.
	_ensure_chat_has_messages()
	_chats[_current_chat]["messages"].append({"role": "user", "text": question})
	_chats[_current_chat]["messages"].append({"role": "assistant", "text": ""})
	_streamed_markdown = ""
	_save_current_chat_activity()
	_clear_activity()
	if thought_history_list:
		thought_history_list.visible = false
	_update_activity_ui()
	_push_activity("Thinking...")
	_render_chat_log()
	scroll_output_to_bottom()

	# Clear input; response will stream in asynchronously (no status line for sending).
	if prompt_text_edit:
		prompt_text_edit.text = ""

	var active_language := "gdscript"
	var active_script_path := ""
	var active_script_text := ""
	var active_scene_path := ""
	var project_root_abs := ProjectSettings.globalize_path("res://")
	if _editor_interface:
		# Prefer selected node's script; fallback to edited scene root's script.
		var scene_root := _editor_interface.get_edited_scene_root()
		if scene_root:
			active_scene_path = scene_root.scene_file_path
		var selected_script: Script = null
		var selection := _editor_interface.get_selection() if _editor_interface else null
		if selection:
			var nodes := selection.get_selected_nodes()
			if nodes and nodes.size() > 0:
				var n: Node = nodes[0]
				if n and n.get_script() is Script:
					selected_script = n.get_script()
		if selected_script == null and scene_root and scene_root.get_script() is Script:
			selected_script = scene_root.get_script()
		if selected_script:
			active_script_path = selected_script.resource_path
			# Works for GDScript; for other Script types this may be empty.
			if "source_code" in selected_script:
				active_script_text = selected_script.source_code

	var payload: Dictionary = {
		"question": question,
		"context": {
			"engine_version": Engine.get_version_info().get("string"),
			"language": active_language,
			"selected_node_type": "",
			"current_script": active_script_path,
			"extra": {
				"active_file_text": active_script_text,
				"active_scene_path": active_scene_path,
				"project_root_abs": project_root_abs,
			}
		},
		"top_k": 5
	}
	if _settings:
		if _settings.openai_api_key.length() > 0:
			payload["api_key"] = _settings.openai_api_key
		if _settings.selected_model.length() > 0:
			payload["model"] = _settings.selected_model
		if _settings.openai_base_url.length() > 0:
			payload["base_url"] = _settings.openai_base_url
	var json_body: String = JSON.stringify(payload)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	if allow_editor_actions_check and allow_editor_actions_check.button_pressed:
		# Stream answer then run tool_calls from trailing __TOOL_CALLS__ line.
		_streaming_in_progress = true
		_update_ask_button_state()
		_async_stream_request(rag_service_url + "/query_stream_with_tools", headers, json_body)
	else:
		_streaming_in_progress = true
		_update_ask_button_state()
		_async_stream_request(rag_service_url + "/query_stream", headers, json_body)


func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	print("AI Assistant: HTTP request completed. result=", result, " code=", response_code)

	if result != HTTPRequest.RESULT_SUCCESS:
		_set_status("Request failed: %d" % result)
		_pending_http_kind = &""
		return

	if response_code < 200 or response_code >= 300:
		_set_status("HTTP error: %d" % response_code)
		_pending_http_kind = &""
		return

	var body_text: String = body.get_string_from_utf8()
	print("AI Assistant: response body: ", body_text)

	var json := JSON.new()
	var parse_result: int = json.parse(body_text)
	if parse_result != OK:
		_set_status("Failed to parse JSON response.")
		_pending_http_kind = &""
		return

	var data := json.data
	if typeof(data) != TYPE_DICTIONARY:
		_set_status("Unexpected response format.")
		_pending_http_kind = &""
		return

	if _pending_http_kind == &"health":
		var status_val: Variant = data.get("status", "")
		if typeof(status_val) == TYPE_STRING and String(status_val) == "ok":
			_set_status("Backend ready.")
		else:
			_set_status("Backend reachable, unexpected /health response.")
		_pending_http_kind = &""
		return

	if _pending_http_kind == &"query":
		_pending_http_kind = &""
		var answer: String = data.get("answer", "")
		var usage_raw = data.get("context_usage", null)
		if typeof(usage_raw) == TYPE_DICTIONARY and _current_chat >= 0 and _current_chat < _chats.size():
			_chats[_current_chat]["context_usage"] = usage_raw
			_update_context_usage_label()
		var tool_calls_raw = data.get("tool_calls", [])
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] = answer
		else:
			messages.append({"role": "assistant", "text": answer})
		_streamed_markdown = ""
		_render_chat_log()
		_set_status("Response received.")
		if tool_calls_raw is Array and tool_calls_raw.size() > 0:
			var summaries: Array = _format_tool_calls_summaries(tool_calls_raw)
			if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
				messages[messages.size() - 1]["tool_calls_summary"] = summaries
			_update_tool_calls_ui()
			if _tool_executor:
				_run_editor_actions_async(tool_calls_raw, false, "tool_action", _last_tool_prompt)
		return

	_pending_http_kind = &""


func _on_copy_button_pressed() -> void:
	if not output_text_edit:
		return
	var text_to_copy := output_text_edit.get_parsed_text()
	if text_to_copy.is_empty():
		_set_status("Nothing to copy.")
		return
	DisplayServer.clipboard_set(text_to_copy)
	_set_status("Copied answer to clipboard.")


func _async_stream_request(endpoint: String, _headers: PackedStringArray, body: String) -> void:
	var client := HTTPClient.new()

	# Simple parsing for URLs like http://host:port/path
	var host: String = ""
	var port: int = 80
	var use_tls := false
	var path: String = ""

	var scheme_split := endpoint.split("://")
	var remainder := ""
	if scheme_split.size() == 2:
		var scheme := scheme_split[0]
		remainder = scheme_split[1]
		if scheme == "https":
			use_tls = true
			port = 443
		else:
			use_tls = false
			port = 80
	else:
		remainder = endpoint

	var first_slash := remainder.find("/")
	var host_port := ""
	if first_slash == -1:
		host_port = remainder
		path = "/"
	else:
		host_port = remainder.substr(0, first_slash)
		path = remainder.substr(first_slash)

	var colon_index := host_port.find(":")
	if colon_index == -1:
		host = host_port
	else:
		host = host_port.substr(0, colon_index)
		var port_str := host_port.substr(colon_index + 1)
		port = int(port_str)

	var tls_options: TLSOptions = null
	if use_tls:
		tls_options = TLSOptions.client()

	var err := client.connect_to_host(host, port, tls_options)
	if err != OK:
		_set_status("Failed to connect to RAG service.")
		return

	_stream_http(client, path, body)


func _stream_http(client: HTTPClient, path: String, body: String) -> void:
	await get_tree().process_frame

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		_set_status("Failed to connect to RAG service.")
		_streaming_in_progress = false
		_update_ask_button_state()
		return

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Content-Length: %d" % body.to_utf8_buffer().size(),
	])
	client.request(HTTPClient.METHOD_POST, path, headers, body)

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_BODY:
		_set_status("Unexpected HTTP status.")
		_streaming_in_progress = false
		_update_ask_button_state()
		return

	_set_status("Receiving response...")

	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			await get_tree().process_frame
			continue
		var delta := chunk.get_string_from_utf8()
		if delta.is_empty():
			await get_tree().process_frame
			continue
		if _streamed_markdown.is_empty():
			_push_activity("Responding...")
		_streamed_markdown += delta
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
			var marker_pos := _streamed_markdown.find(TOOL_CALLS_MARKER)
			if marker_pos >= 0:
				messages[messages.size() - 1]["text"] = _streamed_markdown.substr(0, marker_pos)
			else:
				messages[messages.size() - 1]["text"] = _streamed_markdown
		_render_chat_log()
		await get_tree().process_frame

	# Parse trailing __TOOL_CALLS__ from query_stream_with_tools; never show marker or JSON in chat.
	const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
	const USAGE_MARKER := "\n__USAGE__\n"
	var marker_pos := _streamed_markdown.find(TOOL_CALLS_MARKER)
	print(_LOG_PREFIX + "lint/stream: TOOL_CALLS_MARKER pos=%d" % marker_pos)
	if marker_pos >= 0:
		var display_text := _streamed_markdown.substr(0, marker_pos)
		var tail := _streamed_markdown.substr(marker_pos + TOOL_CALLS_MARKER.length())
		var usage_pos := tail.find(USAGE_MARKER)
		var tool_calls_json := tail.strip_edges()
		var usage_json := ""
		if usage_pos >= 0:
			tool_calls_json = tail.substr(0, usage_pos).strip_edges()
			usage_json = tail.substr(usage_pos + USAGE_MARKER.length()).strip_edges()
		print(_LOG_PREFIX + "lint/stream: tool_calls_json.length=%d" % tool_calls_json.length())
		_streamed_markdown = display_text
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] = display_text
		if not tool_calls_json.is_empty():
			var json := JSON.new()
			var parse_ok := json.parse(tool_calls_json) == OK and json.data is Array
			print(_LOG_PREFIX + "lint/stream: parse tool_calls ok=%s" % parse_ok)
			if parse_ok and json.data is Array:
				var tool_arr: Array = json.data
				print(_LOG_PREFIX + "lint/stream: invoking _run_editor_actions_async with %d tool calls" % tool_arr.size())
				var summaries: Array = _format_tool_calls_summaries(tool_arr)
				if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
					messages[messages.size() - 1]["tool_calls_summary"] = summaries
				_update_tool_calls_ui()
				_run_editor_actions_async(tool_arr, false, "tool_action", _last_tool_prompt)
		_render_chat_log()
		if not usage_json.is_empty():
			var uj := JSON.new()
			if uj.parse(usage_json) == OK and uj.data is Dictionary and _current_chat >= 0 and _current_chat < _chats.size():
				_chats[_current_chat]["context_usage"] = uj.data
				_update_context_usage_label()

	_streaming_in_progress = false
	_update_ask_button_state()
	_set_status("Response received.")


func _update_ask_button_state() -> void:
	if not ask_button:
		return
	if _streaming_in_progress:
		ask_button.disabled = true
		if _ask_icon_busy:
			ask_button.icon = _ask_icon_busy
	else:
		ask_button.disabled = false
		if _ask_icon_idle:
			ask_button.icon = _ask_icon_idle


func _update_context_usage_label() -> void:
	if not context_usage_label:
		return
	var usage: Dictionary = {}
	if _current_chat >= 0 and _current_chat < _chats.size():
		usage = _chats[_current_chat].get("context_usage", {})
	if usage.is_empty():
		context_usage_label.text = "Ctx: --"
		return
	var est := int(usage.get("estimated_prompt_tokens", 0))
	var limit := int(usage.get("limit_tokens", 0))
	var pct := float(usage.get("percent", 0.0))
	if limit > 0:
		context_usage_label.text = "Ctx: %d%% (%d/%d)" % [int(pct * 100.0), est, limit]
	else:
		context_usage_label.text = "Ctx: %d" % est


func _escape_bbcode(t: String) -> String:
	return t.replace("[", "[[")  # RichTextLabel uses [[ for literal [


func scroll_output_to_bottom() -> void:
	if not output_text_edit:
		return
	output_text_edit.scroll_to_line(max(output_text_edit.get_line_count() - 1, 0))


func _save_current_chat_activity() -> void:
	if _current_chat >= 0 and _current_chat < _chats.size():
		var c: Dictionary = _chats[_current_chat]
		c["current_activity"] = _current_activity.duplicate()
		c["activity_history"] = _activity_history.duplicate()


func _push_activity(line: String) -> void:
	if line.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _current_activity.size() > 0:
		_activity_history.append({
			"text": _current_activity["text"],
			"started_at": _current_activity["started_at"],
			"ended_at": now,
		})
	_current_activity = {"text": line, "started_at": now}
	_save_current_chat_activity()
	_stop_activity_glow()
	_update_activity_ui()
	_start_activity_glow()
	_render_chat_log()


func _clear_activity() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _current_activity.size() > 0:
		_activity_history.append({
			"text": _current_activity["text"],
			"started_at": _current_activity["started_at"],
			"ended_at": now,
		})
	_current_activity = {}
	_save_current_chat_activity()
	_stop_activity_glow()
	_update_activity_ui()
	_render_chat_log()


func _format_elapsed(sec: float) -> String:
	if sec < 1.0:
		return "%.1fs" % sec
	elif sec < 60.0:
		return "%.0fs" % sec
	else:
		return "%dm %.0fs" % [int(sec / 60.0), fmod(sec, 60.0)]


func _update_activity_ui() -> void:
	if current_activity_label:
		if _current_activity.size() > 0:
			current_activity_label.text = _current_activity["text"]
			current_activity_label.visible = true
		else:
			current_activity_label.text = ""
			current_activity_label.visible = false
	if thought_history_button:
		var n := _activity_history.size()
		thought_history_button.visible = n > 0
		thought_history_button.text = "Thought history (%d)" % n + (" ▼" if thought_history_list.visible else " ▶")
	if thought_history_list:
		for c in thought_history_list.get_children():
			c.queue_free()
		# Newest first; each row: "Activity text   elapsed"
		for i in range(_activity_history.size() - 1, -1, -1):
			var h: Dictionary = _activity_history[i]
			var elapsed: float = float(h.get("ended_at", 0) - h.get("started_at", 0))
			var elapsed_str := _format_elapsed(elapsed)
			var l := Label.new()
			l.text = "  %s   %s" % [str(h.get("text", "")), elapsed_str]
			l.add_theme_font_size_override("font_size", 12)
			l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
			thought_history_list.add_child(l)


func _start_activity_glow() -> void:
	if not current_activity_label or _current_activity.is_empty():
		return
	_stop_activity_glow()
	_activity_glow_tween = create_tween()
	_activity_glow_tween.set_loops()
	_activity_glow_tween.tween_property(current_activity_label, "modulate:a", 0.65, 0.45)
	_activity_glow_tween.tween_property(current_activity_label, "modulate:a", 1.0, 0.45)


func _stop_activity_glow() -> void:
	if _activity_glow_tween:
		_activity_glow_tween.kill()
		_activity_glow_tween = null
	if current_activity_label:
		current_activity_label.modulate.a = 1.0


func _on_thought_history_toggled() -> void:
	if thought_history_list:
		thought_history_list.visible = not thought_history_list.visible
	if thought_history_button and _activity_history.size() > 0:
		thought_history_button.text = "Thought history (%d)" % _activity_history.size() + (" ▼" if thought_history_list.visible else " ▶")


func _on_tool_calls_toggled() -> void:
	if tool_calls_list and tool_calls_button:
		tool_calls_list.visible = not tool_calls_list.visible
		_update_tool_calls_button_label()


func _update_tool_calls_button_label() -> void:
	if not tool_calls_button:
		return
	var n := 0
	if _current_chat >= 0 and _current_chat < _chats.size():
		var messages: Array = _chats[_current_chat].get("messages", [])
		for i in range(messages.size() - 1, -1, -1):
			var msg = messages[i]
			if typeof(msg) == TYPE_DICTIONARY and msg.get("role", "") == "assistant":
				var summary: Array = msg.get("tool_calls_summary", [])
				if summary.size() > 0:
					n = summary.size()
					break
	tool_calls_button.text = "Tool calls (%d)" % n + (" ▼" if (tool_calls_list and tool_calls_list.visible) else " ▶")


func _update_tool_calls_ui() -> void:
	if not tool_calls_button or not tool_calls_list:
		return
	var summaries: Array = []
	if _current_chat >= 0 and _current_chat < _chats.size():
		var messages: Array = _chats[_current_chat].get("messages", [])
		for i in range(messages.size() - 1, -1, -1):
			var msg = messages[i]
			if typeof(msg) == TYPE_DICTIONARY and msg.get("role", "") == "assistant":
				summaries = msg.get("tool_calls_summary", [])
				break
	if summaries.is_empty():
		tool_calls_button.visible = false
		tool_calls_list.visible = false
		return
	tool_calls_button.visible = true
	for c in tool_calls_list.get_children():
		c.queue_free()
	for j in range(summaries.size()):
		var line: String = str(summaries[j]) if j < summaries.size() else ""
		var l := Label.new()
		l.text = "  %d. %s" % [j + 1, line]
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.55, 0.65, 0.55, 1.0))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tool_calls_list.add_child(l)
	tool_calls_list.visible = false
	_update_tool_calls_button_label()


func _process(_delta: float) -> void:
	# Update current activity label with live elapsed (e.g. "Thinking... 1.2s")
	if _current_activity.is_empty() or not current_activity_label or not current_activity_label.visible:
		return
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - float(_current_activity.get("started_at", 0.0))
	current_activity_label.text = "%s   %s" % [_current_activity["text"], _format_elapsed(elapsed)]


func _render_chat_log() -> void:
	print(_LOG_PREFIX + "lint/render: _render_chat_log START")
	if not output_text_edit:
		print(_LOG_PREFIX + "lint/render: output_text_edit null, return")
		return
	_ensure_chat_has_messages()
	var messages: Array = _chats[_current_chat]["messages"]
	print(_LOG_PREFIX + "lint/render: messages.size=%d" % messages.size())
	var parts: Array[String] = []
	var width := int(output_text_edit.size.x)
	var font_size := int(output_text_edit.get_theme_font_size("normal_font_size"))
	if font_size <= 0:
		font_size = 18
	var approx_char_px := max(6.0, float(font_size) * 0.60)
	# Cap divider to one line so it doesn't wrap when dock is narrow
	var chars_fit := int(float(width) / approx_char_px) if width > 0 else 40
	var divider_chars := clampi(max(24, min(chars_fit, 200)), 24, 200)
	var divider := "─".repeat(divider_chars)
	var idx := 0
	for msg in messages:
		var role: String = msg.get("role", "assistant")
		var text: String = msg.get("text", "")
		var is_last := idx == messages.size() - 1
		var is_streaming_assistant := _streaming_in_progress and is_last and role == "assistant"
		if role == "user":
			# User: distinct block, right-aligned; neutral styling.
			parts.append("[color=#b0b0b0][b]You[/b][/color]\n[color=#e0e0e0][right]" + _escape_bbcode(text) + "[/right][/color]")
		else:
			# Assistant: neutral block; show typing cursor while streaming.
			var assistant_bb := _markdown_renderer.markdown_to_bbcode(text)
			var cursor_bb := "[color=#c0c0c0]▌[/color]" if is_streaming_assistant else ""
			parts.append("[color=#b0b0b0][b]Assistant[/b][/color]\n[color=#e0e0e0]" + assistant_bb + cursor_bb + "[/color]")
		parts.append("[color=#44485588]" + divider + "[/color]\n")
		idx += 1
	# Activity is shown in ActivityBlock (current line + thought history dropdown), not inline.
	var bbcode: String = "\n".join(parts)
	print(_LOG_PREFIX + "lint/render: bbcode.length=%d" % bbcode.length())
	var was_at_bottom: bool = _is_output_at_bottom()
	output_text_edit.clear()
	output_text_edit.text = bbcode
	if was_at_bottom:
		scroll_output_to_bottom()
	print(_LOG_PREFIX + "lint/render: _render_chat_log DONE")


func _is_output_at_bottom() -> bool:
	if not output_text_edit:
		return true
	var vbar: VScrollBar = output_text_edit.get_v_scroll_bar()
	if vbar == null:
		return true
	return (vbar.max_value - vbar.value) <= _SCROLL_AT_BOTTOM_THRESHOLD


func _update_output_from_markdown() -> void:
	_render_chat_log()


## Return human-readable one-line summary per tool call for the dropdown (no raw JSON).
func _format_tool_calls_summaries(tool_calls: Array) -> Array:
	var out: Array = []
	for tc in tool_calls:
		if typeof(tc) != TYPE_DICTIONARY:
			out.append("(invalid)")
			continue
		var name_key := str(tc.get("tool_name", tc.get("name", "")))
		var args: Dictionary = tc.get("arguments", {})
		if typeof(args) != TYPE_DICTIONARY:
			args = {}
		var payload := _executor_payload_from_tool_call(tc)
		var action := str(payload.get("action", name_key))
		var parts: Array[String] = [action]
		if action == "write_file" or action == "apply_patch" or action == "create_file" or action == "create_script" or action == "delete_file":
			var path_val := payload.get("path", args.get("path", ""))
			if path_val:
				parts.append(str(path_val))
		elif action == "create_node":
			var class_name_val := payload.get("class_name", args.get("class_name", ""))
			var parent_val := payload.get("parent_path", args.get("parent_path", ""))
			if class_name_val:
				parts.append(str(class_name_val))
			if parent_val:
				parts.append(" in " + str(parent_val))
		elif action == "set_node_property":
			var node_val := payload.get("node_path", args.get("node_path", ""))
			var prop_val := payload.get("property", args.get("property", ""))
			if node_val:
				parts.append(str(node_val))
			if prop_val:
				parts.append(" ." + str(prop_val))
		elif action == "read_file" or action == "lint_file" or action == "list_directory" or action == "search_files":
			var path_val := payload.get("path", args.get("path", ""))
			if path_val:
				parts.append(str(path_val))
		out.append(" ".join(parts))
	return out


## Build the payload the executor expects. Backend sends { tool_name, arguments, output }.
## If output has execute_on_client we use it; else we build from tool_name + arguments so no tool call is dropped.
func _executor_payload_from_tool_call(tc: Dictionary) -> Dictionary:
	var out = tc.get("output", null)
	if typeof(out) == TYPE_DICTIONARY and out.get("execute_on_client", false):
		return out
	var name_key := tc.get("tool_name", "")
	if name_key.is_empty():
		name_key = tc.get("name", "")
	var args: Dictionary = tc.get("arguments", {})
	if typeof(args) != TYPE_DICTIONARY:
		args = {}
	var payload: Dictionary = {
		"execute_on_client": true,
		"action": str(name_key),
	}
	for k in args:
		payload[k] = args[k]
	return payload


const _MAX_TOOL_CALLS_PER_RESPONSE := 20  # Avoid editor crash from too many actions in one go

func _run_editor_actions_async(tool_calls: Array, proposal_mode: bool, trigger: String = "", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	print(_LOG_PREFIX + "lint/actions: _run_editor_actions_async START, tool_calls.size=%d" % tool_calls.size())
	var results: Array[String] = []
	var display_changes: Array = []  # { action_type, summary, message } for chat + timeline
	if _tool_executor:
		_tool_executor.set_follow_agent(follow_agent_check.button_pressed if follow_agent_check else false)
	var edit_records: Array = []  # file-only, for backend
	var effective_trigger := trigger if not trigger.is_empty() else _last_tool_trigger
	var effective_prompt := prompt if not prompt.is_empty() else _last_tool_prompt
	var effective_lint_before := lint_errors_before.strip_edges()
	var effective_lint_after := lint_errors_after.strip_edges()
	var total := tool_calls.size()
	var skipped := 0
	if total > _MAX_TOOL_CALLS_PER_RESPONSE:
		skipped = total - _MAX_TOOL_CALLS_PER_RESPONSE
		tool_calls = tool_calls.slice(0, _MAX_TOOL_CALLS_PER_RESPONSE)
	var tree := get_tree()
	for tc in tool_calls:
		if typeof(tc) != TYPE_DICTIONARY:
			continue
		var out := _executor_payload_from_tool_call(tc)
		if out.is_empty() or not out.get("execute_on_client", false):
			continue
		var action: String = str(out.get("action", ""))
		if action.is_empty():
			continue
		_push_activity("Using tool: %s" % action)
		# File edits: apply immediately (staged like Cursor); show in timeline with green/red in editor; user can Revert if needed.
		if action in ["create_file", "write_file", "apply_patch", "create_script", "delete_file"]:
			if action in ["create_file", "write_file"] and str(out.get("content", "")).strip_edges().length() < 10:
				results.append("Error: %s had no or empty content (model did not generate the file). Review the answer and ask again." % action)
				continue
			_set_status("Applying: %s..." % str(out.get("path", action)))
			var file_result: Dictionary = await _tool_executor.execute_async(out)
			var msg := file_result.get("message", "OK") if file_result.get("success", false) else ("Error: %s" % file_result.get("message", "unknown"))
			results.append(msg)
			var rec2 = file_result.get("edit_record", null)
			if rec2 != null and rec2 is Dictionary:
				var rec_dict: Dictionary = rec2
				edit_records.append(rec_dict)
				var path := str(rec_dict.get("file_path", ""))
				var lint_ok := true
				if file_result.get("success", false) and _should_lint_path(path):
					_push_activity("Linting: %s" % path)
					_set_status("Linting: %s..." % path)
					lint_ok = await _lint_and_autofix_return_ok(path, 5)
				display_changes.append({
					"action_type": rec_dict.get("action_type", action),
					"summary": rec_dict.get("summary", msg),
					"message": msg,
					"file_path": path,
					"lint_ok": lint_ok,
				})
				if _edit_store:
					_edit_store.add_applied_file_change(rec_dict, lint_ok, str(rec_dict.get("action_type", "")))
			continue

		# modify_attribute: routes to node property or import option; result has edit_record for either.
		if action == "modify_attribute":
			_set_status("Applying: %s..." % action)
			var mod_result: Dictionary = await _tool_executor.execute_async(out)
			var mod_msg := mod_result.get("message", "OK") if mod_result.get("success", false) else ("Error: %s" % mod_result.get("message", "unknown"))
			results.append(mod_msg)
			var mod_rec = mod_result.get("edit_record", null)
			if mod_rec != null and mod_rec is Dictionary:
				var mr: Dictionary = mod_rec
				display_changes.append({
					"action_type": mr.get("action_type", action),
					"summary": mr.get("summary", mod_msg),
					"message": mod_msg,
				})
				# Import: file_path present -> file edit (timeline, revert, lint)
				if mr.has("file_path"):
					edit_records.append(mr)
					var path := str(mr.get("file_path", ""))
					var lint_ok := true
					if mod_result.get("success", false) and _should_lint_path(path):
						_push_activity("Linting: %s" % path)
						lint_ok = await _lint_and_autofix_return_ok(path, 5)
					display_changes[display_changes.size() - 1]["file_path"] = path
					display_changes[display_changes.size() - 1]["lint_ok"] = lint_ok
					if _edit_store:
						_edit_store.add_applied_file_change(mr, lint_ok, str(mr.get("action_type", "")))
				# Node: scene_path present -> node change
				elif mr.has("scene_path") and _edit_store and mod_result.get("success", false):
					var scene_path := str(mr.get("scene_path", ""))
					var node_path := str(mr.get("node_path", ""))
					var status := "modified"
					if str(mr.get("action_type", "")) == "create_node":
						status = "created"
					_edit_store.add_node_change(scene_path, node_path, status, str(mr.get("summary", mod_msg)), str(mr.get("action_type", "")))
			continue

		# Other editor tools: read_file, list_directory, list_files, search_files, read_import_options, lint_file, create_node.
		# lint_file: run via backend so we never spawn Godot from inside the editor (crashes).
		print(_LOG_PREFIX + "lint/actions: running tool action=%s" % action)
		_set_status("Running: %s..." % action)
		var result: Dictionary
		if action == "lint_file":
			var path_for_lint := str(out.get("path", ""))
			result = await _request_backend_lint(path_for_lint)
		else:
			result = await _tool_executor.execute_async(out)
		print(_LOG_PREFIX + "lint/actions: tool action=%s returned, success=%s" % [action, result.get("success", false)])
		var node_msg := result.get("message", "OK") if result.get("success", false) else ("Error: %s" % result.get("message", "unknown"))
		results.append(node_msg)
		if action == "lint_file":
			print(_LOG_PREFIX + "lint/actions: handling lint_file result")
			var lint_out := str(result.get("output", "")).strip_edges()
			print(_LOG_PREFIX + "lint/actions: lint_file output length=%d" % lint_out.length())
			if not lint_out.is_empty():
				# Use concatenation so lint output (which may contain %) does not break format strings
				print(_LOG_PREFIX + "lint/actions: appending lint_file to display_changes")
				display_changes.append({
					"action_type": "lint_file",
					"summary": "Lint: %s" % str(out.get("path", "")),
					"message": "```\n" + lint_out + "\n```",
				})
				print(_LOG_PREFIX + "lint/actions: display_changes.size=%d" % display_changes.size())
		var node_rec = result.get("edit_record", null)
		if node_rec != null and node_rec is Dictionary:
			var nr: Dictionary = node_rec
			display_changes.append({
				"action_type": nr.get("action_type", action),
				"summary": nr.get("summary", node_msg),
				"message": node_msg,
			})
			if _edit_store and result.get("success", false):
				var scene_path := str(nr.get("scene_path", ""))
				var node_path := str(nr.get("node_path", ""))
				var status := "modified"
				if str(nr.get("action_type", "")) == "create_node":
					status = "created"
				_edit_store.add_node_change(scene_path, node_path, status, str(nr.get("summary", node_msg)), str(nr.get("action_type", "")))

	if edit_records.size() > 0:
		await _log_edit_event_to_backend(edit_records, effective_trigger, effective_prompt, effective_lint_before, effective_lint_after)
	if skipped > 0:
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] += "\n\n_Skipped %d tool call(s) to avoid overload. Ask for fewer changes at a time._" % skipped
		_render_chat_log()
	if display_changes.size() > 0:
		_set_status("Editor actions: %d change(s)" % display_changes.size())
		var section: String = _format_editor_actions_chat_section(display_changes)
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] += section
		_render_chat_log()
	else:
		_set_status("Response received.")

	# Defer so chat is visible first; if changes/decorations crash (e.g. broken scripts), user still sees the result
	print(_LOG_PREFIX + "lint/actions: about to call_deferred _render_changes_tab")
	call_deferred("_render_changes_tab")
	print(_LOG_PREFIX + "lint/actions: about to call_deferred _apply_editor_decorations")
	call_deferred("_apply_editor_decorations")
	print(_LOG_PREFIX + "lint/actions: _run_editor_actions_async finished (deferred calls queued)")

	# Changes are applied immediately; user can revert from Pending & Timeline tab if needed.


func _format_editor_actions_chat_section(display_changes: Array) -> String:
	print(_LOG_PREFIX + "lint/format: _format_editor_actions_chat_section START size=%d" % display_changes.size())
	if display_changes.is_empty():
		print(_LOG_PREFIX + "lint/format: display_changes empty, return")
		return ""
	var lines: PackedStringArray = []
	lines.append("")
	lines.append("**Editor actions**")
	lines.append("")
	for i in range(display_changes.size()):
		var c = display_changes[i]
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var action_type := str(c.get("action_type", ""))
		print(_LOG_PREFIX + "lint/format: change[%d] action_type=%s" % [i, action_type])
		var summary := str(c.get("summary", c.get("message", "")))
		var icon := GodotAIEditStore.get_action_icon(action_type)
		var label := GodotAIEditStore.get_action_label(action_type)
		var lint_note := ""
		if c.has("lint_ok") and _should_lint_path(str(c.get("file_path", ""))):
			lint_note = " (Lint: %s)" % ("passed" if c.get("lint_ok", true) else "failed")
		# Use concatenation so summary/message (paths, lint output) never break format strings
		lines.append("- " + icon + " **" + label + "**: " + summary + lint_note)
		if action_type == "lint_file" and c.has("message"):
			var msg := str(c.get("message", ""))
			print(_LOG_PREFIX + "lint/format: appending lint_file message length=%d" % msg.length())
			lines.append(msg)
	lines.append("")
	var result := "\n".join(lines)
	print(_LOG_PREFIX + "lint/format: _format_editor_actions_chat_section DONE result.length=%d" % result.length())
	return result


func _render_changes_tab() -> void:
	print(_LOG_PREFIX + "lint/tab: _render_changes_tab START (deferred)")
	if _edit_store == null:
		print(_LOG_PREFIX + "lint/tab: _edit_store null, return")
		return
	if pending_list:
		pending_list.clear()
		_selected_pending_id = ""
		for p in _edit_store.pending:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var action_type := str(p.get("action_type", ""))
			var icon := GodotAIEditStore.get_action_icon(action_type)
			var label := "%s %s" % [icon, str(p.get("summary", ""))]
			pending_list.add_item(label)
	if timeline_list:
		timeline_list.clear()
		_selected_timeline_id = ""
		for e in _edit_store.events:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var action_type := str(e.get("action_type", ""))
			var icon := GodotAIEditStore.get_action_icon(action_type)
			var summary := str(e.get("summary", ""))
			var label := "%s %s" % [icon, summary]
			timeline_list.add_item(label)
	_show_diff("", "")
	print(_LOG_PREFIX + "lint/tab: _render_changes_tab DONE")


func _show_diff(old_content: String, new_content: String) -> void:
	var old_te: TextEdit = diff_old_text if diff_old_text else get_node_or_null("TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/RightVBox/DiffSplit/OldText") as TextEdit
	var new_te: TextEdit = diff_new_text if diff_new_text else get_node_or_null("TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/RightVBox/DiffSplit/NewText") as TextEdit
	if old_te:
		old_te.text = old_content
		old_te.scroll_vertical = 0
		old_te.queue_redraw()
	if new_te:
		new_te.text = new_content
		new_te.scroll_vertical = 0
		new_te.queue_redraw()


func _on_pending_item_selected(index: int) -> void:
	if _edit_store == null:
		return
	if index < 0 or index >= _edit_store.pending.size():
		return
	var p = _edit_store.pending[index]
	if typeof(p) != TYPE_DICTIONARY:
		return
	_selected_pending_id = str(p.get("id", ""))
	_show_diff(str(p.get("old_content", "")), str(p.get("new_content", "")))


func _on_revert_selected_pressed() -> void:
	if _edit_store == null or _tool_executor == null:
		return
	if _selected_timeline_id.is_empty():
		_set_status("Select a file change in the timeline to revert.")
		return
	var info = _edit_store.get_revert_info(_selected_timeline_id)
	if info.is_empty():
		_set_status("Selected item cannot be reverted (not a file edit or no previous content).")
		return
	var path := str(info.get("file_path", ""))
	var old_content := str(info.get("old_content", ""))
	_set_status("Reverting: %s..." % path)
	var result: Dictionary = _tool_executor.execute({
		"execute_on_client": true,
		"action": "write_file",
		"path": path,
		"content": old_content,
	})
	if result.get("success", false):
		_edit_store.clear_file_status(path)
		_set_status("Reverted: %s" % path)
	else:
		_set_status("Revert failed: %s" % result.get("message", "unknown"))
	_render_changes_tab()
	_apply_editor_decorations()


func _on_timeline_item_selected(index: int) -> void:
	if _edit_store == null:
		return
	if index < 0 or index >= _edit_store.events.size():
		return
	var e = _edit_store.events[index]
	if typeof(e) != TYPE_DICTIONARY:
		return
	_selected_timeline_id = str(e.get("id", ""))
	if str(e.get("kind", "")) == "file":
		_show_diff(str(e.get("old_content", "")), str(e.get("new_content", "")))
	else:
		_show_diff("", "")


func _read_text_res(path: String) -> String:
	if path.is_empty():
		return ""
	var p := path
	if p.begins_with("res://"):
		p = p.substr("res://".length())
	var abs := ProjectSettings.globalize_path("res://").path_join(p)
	if not FileAccess.file_exists(abs):
		return ""
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null:
		return ""
	var txt := f.get_as_text()
	f.close()
	return txt


func _post_lint_fix_to_backend(file_path: String, lint_output: String, old_content: String, new_content: String, prompt: String) -> void:
	var endpoint := rag_service_url + "/lint_memory/record_fix"
	var payload: Dictionary = {
		"project_root_abs": ProjectSettings.globalize_path("res://"),
		"file_path": file_path,
		"engine_version": Engine.get_version_info().get("string"),
		"raw_lint_output": lint_output,
		"old_content": old_content,
		"new_content": new_content,
		"prompt": prompt,
	}
	var body := JSON.stringify(payload)
	await _query_backend_json(endpoint, HTTPClient.METHOD_POST, body)


func _lint_and_autofix_return_ok(res_path: String, max_rounds: int) -> bool:
	print(_LOG_PREFIX + "lint/autofix: _lint_and_autofix_return_ok START res_path=%s max_rounds=%d" % [res_path, max_rounds])
	var project_dir := ProjectSettings.globalize_path("res://")
	var rel_path := res_path
	if rel_path.begins_with("res://"):
		rel_path = rel_path.substr("res://".length())

	var original_before_any_fix := _read_text_res(res_path)
	var first_failure_output := ""

	for attempt in range(max_rounds):
		print(_LOG_PREFIX + "lint/autofix: attempt %d/%d" % [attempt + 1, max_rounds])
		var lint := await _run_headless_lint(project_dir, rel_path)
		var ok: bool = lint.get("ok", false)
		if ok:
			print(_LOG_PREFIX + "lint/autofix: lint passed, return true")
			if not first_failure_output.is_empty():
				var final_after := _read_text_res(res_path)
				if not final_after.is_empty() and final_after != original_before_any_fix:
					await _post_lint_fix_to_backend(res_path, first_failure_output, original_before_any_fix, final_after, _last_tool_prompt)
			return true
		var lint_output: String = str(lint.get("output", "")).strip_edges()
		if lint_output.is_empty():
			lint_output = "Lint failed but produced no output."
		if first_failure_output.is_empty():
			first_failure_output = lint_output
		_push_activity("Fixing lint errors (attempt %d/%d)..." % [attempt + 1, max_rounds])
		var fix_question := (
			"Fix the lint errors in this file and only change what is necessary.\n"
			+ "File: %s\n"
			+ "Project root: res://\n"
			+ "Lint output:\n%s\n\n"
			+ "Use editor tools (apply_patch or write_file) to update the file.\n"
			+ "After making edits, assume lint will be rerun; keep iterating until it passes."
		) % [res_path, lint_output]
		var file_content := _read_text_res(res_path)
		print(_LOG_PREFIX + "lint/autofix: calling _query_backend_for_tools for fix")
		var fix_resp := await _query_backend_for_tools(fix_question, lint_output, res_path, file_content)
		print(_LOG_PREFIX + "lint/autofix: _query_backend_for_tools returned")
		var tool_calls := fix_resp.get("tool_calls", [])
		if tool_calls is Array and tool_calls.size() > 0 and _tool_executor:
			print(_LOG_PREFIX + "lint/autofix: calling _run_editor_actions_async for fix, tool_calls.size=%d" % tool_calls.size())
			await _run_editor_actions_async(tool_calls, false, "lint_fix", fix_question, lint_output, "")
			print(_LOG_PREFIX + "lint/autofix: _run_editor_actions_async returned")
		else:
			_post_system_message(
				("Auto-lint failed on %s (attempt %d/%d), but the backend did not return any tool calls to fix it.\n\nLint output:\n%s")
				% [res_path, attempt + 1, max_rounds, lint_output]
			)
			return false
	print(_LOG_PREFIX + "lint/autofix: max_rounds reached, running final lint")
	var final_lint := await _run_headless_lint(project_dir, rel_path)
	var final_ok := bool(final_lint.get("ok", false))
	print(_LOG_PREFIX + "lint/autofix: _lint_and_autofix_return_ok DONE return %s" % final_ok)
	return final_ok


func _apply_editor_decorations() -> void:
	if _decorator:
		_decorator.apply_decorations()


func _log_edit_event_to_backend(edit_records: Array, trigger: String = "tool_action", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	var endpoint := rag_service_url + "/edit_events/create"
	var changes: Array = []
	for r in edit_records:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		changes.append({
			"file_path": str(r.get("file_path", "")),
			"change_type": str(r.get("change_type", "modify")),
			"old_content": str(r.get("old_content", "")),
			"new_content": str(r.get("new_content", "")),
		})
	if changes.is_empty():
		return

	var summary := "Edited %d file(s)" % changes.size()
	if changes.size() == 1:
		summary = "%s %s" % [str(changes[0].get("change_type", "modify")), str(changes[0].get("file_path", ""))]

	var payload: Dictionary = {
		"actor": "ai",
		"trigger": trigger if not trigger.is_empty() else "tool_action",
		"summary": summary,
		"changes": changes,
	}
	if not prompt.is_empty():
		payload["prompt"] = prompt
	if not lint_errors_before.is_empty():
		payload["lint_errors_before"] = lint_errors_before
	if not lint_errors_after.is_empty():
		payload["lint_errors_after"] = lint_errors_after
	var body := JSON.stringify(payload)

	var client := HTTPClient.new()
	var scheme_split := endpoint.split("://")
	var remainder := scheme_split[1] if scheme_split.size() == 2 else endpoint
	var first_slash := remainder.find("/")
	var host_port := remainder if first_slash == -1 else remainder.substr(0, first_slash)
	var path := "/" if first_slash == -1 else remainder.substr(first_slash)
	var host := host_port
	var port := 80
	var colon_index := host_port.find(":")
	if colon_index != -1:
		host = host_port.substr(0, colon_index)
		port = int(host_port.substr(colon_index + 1))

	var err := client.connect_to_host(host, port)
	if err != OK:
		return
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Content-Length: %d" % body.to_utf8_buffer().size()
	])
	client.request(HTTPClient.METHOD_POST, path, headers, body)
	# Fire-and-forget; consume response so the connection completes.
	while client.get_status() in [HTTPClient.STATUS_REQUESTING, HTTPClient.STATUS_BODY]:
		client.poll()
		client.read_response_body_chunk()
		await get_tree().process_frame


func _should_lint_path(path: String) -> bool:
	var p := path.to_lower()
	return p.ends_with(".gd") or p.ends_with(".cs") or p.ends_with(".gdshader")


func _lint_and_autofix(res_path: String, max_rounds: int) -> void:
	# Lint runs via backend POST /lint. Then asks the backend to fix any lint output and retries.
	var project_dir := ProjectSettings.globalize_path("res://")
	var rel_path := res_path
	if rel_path.begins_with("res://"):
		rel_path = rel_path.substr("res://".length())

	for attempt in range(max_rounds):
		var lint := await _run_headless_lint(project_dir, rel_path)
		var ok: bool = lint.get("ok", false)
		if ok:
			return

		var lint_output: String = str(lint.get("output", "")).strip_edges()
		if lint_output.is_empty():
			lint_output = "Lint failed but produced no output."

		# Ask backend to fix this file to satisfy the linter.
		_push_activity("Fixing lint errors (attempt %d/%d)..." % [attempt + 1, max_rounds])
		var fix_question := (
			"Fix the lint errors in this file and only change what is necessary.\n"
			+ "File: %s\n"
			+ "Project root: res://\n"
			+ "Lint output:\n%s\n\n"
			+ "Use editor tools (apply_patch or write_file) to update the file.\n"
			+ "After making edits, assume lint will be rerun; keep iterating until it passes."
		) % [res_path, lint_output]
		var file_content := _read_text_res(res_path)
		var fix_resp := await _query_backend_for_tools(fix_question, lint_output, res_path, file_content)
		var tool_calls := fix_resp.get("tool_calls", [])
		if tool_calls is Array and tool_calls.size() > 0 and _tool_executor:
			await _run_editor_actions_async(tool_calls, false, "lint_fix", fix_question, lint_output, "")
		else:
			_post_system_message(
				("Auto-lint failed on %s (attempt %d/%d), but the backend did not return any tool calls to fix it.\n\nLint output:\n%s")
				% [res_path, attempt + 1, max_rounds, lint_output]
			)
			return

	# If we get here, we tried max_rounds and still failed.
	var final_lint := await _run_headless_lint(project_dir, rel_path)
	var final_output: String = str(final_lint.get("output", "")).strip_edges()
	_post_system_message(
		("Gave up after %d auto-fix attempts; lint is still failing for %s.\n\nLast lint output:\n%s")
		% [max_rounds, res_path, final_output]
	)


## Lint via backend (POST /lint). Avoids spawning Godot from inside the editor, which can crash it.
func _request_backend_lint(res_path: String) -> Dictionary:
	var base := (rag_service_url as String).strip_edges().trim_suffix("/")
	if base.is_empty():
		return {"success": false, "message": "Lint requires the RAG backend. Start it (e.g. run_backend.ps1) and set the backend URL in Settings.", "path": res_path, "output": "", "exit_code": -1}
	var url := base + "/lint"
	var project_root_abs := ProjectSettings.globalize_path("res://")
	var body := JSON.stringify({"project_root_abs": project_root_abs, "path": res_path})
	var req := HTTPRequest.new()
	add_child(req)
	req.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	var args: Array = await req.request_completed
	req.queue_free()
	if args[0] != HTTPRequest.RESULT_SUCCESS:
		return {"success": false, "message": "Lint request failed", "path": res_path, "output": "", "exit_code": -1}
	var resp_body: PackedByteArray = args[3]
	var json := JSON.new()
	if json.parse(resp_body.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {"success": false, "message": "Invalid lint response", "path": res_path, "output": "", "exit_code": -1}
	var d: Dictionary = json.data
	var ok := bool(d.get("success", false))
	var out_text := str(d.get("output", "")).strip_edges()
	return {"success": ok, "message": "Lint passed" if ok else "Lint reported issues", "path": res_path, "output": out_text, "exit_code": int(d.get("exit_code", -1))}


func _run_headless_lint(_project_dir_abs: String, rel_path_from_res: String) -> Dictionary:
	# Use backend /lint so we never spawn Godot from inside the editor (crashes). Return shape expected by autofix: ok, exit_code, output.
	var res_path := "res://" + rel_path_from_res.trim_prefix("/")
	var d := await _request_backend_lint(res_path)
	return {"ok": d.get("success", false), "exit_code": d.get("exit_code", -1), "output": d.get("output", "")}


func _query_backend_for_tools(question: String, lint_output: String = "", override_file_path: String = "", override_file_text: String = "") -> Dictionary:
	# Remember prompt so any tool-driven edits can be attributed.
	_last_tool_prompt = question
	_last_tool_trigger = "tool_action"
	var endpoint := rag_service_url + "/query"
	var active_script_path := ""
	var active_script_text := ""
	var active_scene_path := ""
	var project_root_abs := ProjectSettings.globalize_path("res://")
	if not override_file_path.is_empty():
		# Lint-fix mode: use the file we are fixing so the backend has the right active file.
		active_script_path = override_file_path
		active_script_text = override_file_text if not override_file_text.is_empty() else _read_text_res(override_file_path)
	elif _editor_interface:
		var scene_root := _editor_interface.get_edited_scene_root()
		if scene_root:
			active_scene_path = scene_root.scene_file_path
		var selected_script: Script = null
		var selection := _editor_interface.get_selection() if _editor_interface else null
		if selection:
			var nodes := selection.get_selected_nodes()
			if nodes and nodes.size() > 0:
				var n: Node = nodes[0]
				if n and n.get_script() is Script:
					selected_script = n.get_script()
		if selected_script == null and scene_root and scene_root.get_script() is Script:
			selected_script = scene_root.get_script()
		if selected_script:
			active_script_path = selected_script.resource_path
			if "source_code" in selected_script:
				active_script_text = selected_script.source_code

	var payload: Dictionary = {
		"question": question,
		"context": {
			"engine_version": Engine.get_version_info().get("string"),
			"language": "gdscript",
			"selected_node_type": "",
			"current_script": active_script_path,
			"extra": {
				"active_file_text": active_script_text,
				"active_scene_path": active_scene_path,
				"project_root_abs": project_root_abs,
				"lint_output": lint_output,
			}
		},
		"top_k": 3
	}
	if _settings:
		if _settings.openai_api_key.length() > 0:
			payload["api_key"] = _settings.openai_api_key
		if _settings.selected_model.length() > 0:
			payload["model"] = _settings.selected_model
		if _settings.openai_base_url.length() > 0:
			payload["base_url"] = _settings.openai_base_url

	var body := JSON.stringify(payload)

	# Minimal HTTP POST using HTTPClient (same parsing logic as streaming, but read whole body).
	var client := HTTPClient.new()
	var scheme_split := endpoint.split("://")
	var remainder := scheme_split[1] if scheme_split.size() == 2 else endpoint
	var first_slash := remainder.find("/")
	var host_port := remainder if first_slash == -1 else remainder.substr(0, first_slash)
	var path := "/" if first_slash == -1 else remainder.substr(first_slash)
	var host := host_port
	var port := 80
	var colon_index := host_port.find(":")
	if colon_index != -1:
		host = host_port.substr(0, colon_index)
		port = int(host_port.substr(colon_index + 1))

	var err := client.connect_to_host(host, port)
	if err != OK:
		return {}

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {}

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Content-Length: %d" % body.to_utf8_buffer().size()
	])
	client.request(HTTPClient.METHOD_POST, path, headers, body)

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_BODY:
		return {}

	var response_bytes := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			response_bytes.append_array(chunk)
		await get_tree().process_frame

	var body_text := response_bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(body_text) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func _post_system_message(text: String) -> void:
	_ensure_chat_has_messages()
	var messages: Array = _chats[_current_chat]["messages"]
	messages.append({"role": "assistant", "text": text})
	_render_chat_log()


func _ensure_chat_has_messages() -> void:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return
	var chat: Dictionary = _chats[_current_chat]
	if not chat.has("prompt_draft"):
		chat["prompt_draft"] = ""
	if not chat.has("current_activity"):
		chat["current_activity"] = {}
	if not chat.has("activity_history"):
		chat["activity_history"] = []
	if not chat.has("messages"):
		# Migrate old transcript to a single assistant message
		var transcript: String = chat.get("transcript", "")
		chat["messages"] = []
		if transcript.strip_edges().length() > 0:
			chat["messages"].append({"role": "assistant", "text": transcript})
		chat.erase("transcript")
	if not chat.has("context_usage"):
		chat["context_usage"] = {}


func _ensure_default_chat() -> void:
	if chat_tab_bar == null:
		return
	if _chats.is_empty():
		var title := "Chat 1"
		_chats.append({"title": title, "messages": [], "context_usage": {}, "prompt_draft": "", "current_activity": {}, "activity_history": []})
		chat_tab_bar.clear_tabs()
		chat_tab_bar.add_tab(title)
		_current_chat = 0
		chat_tab_bar.current_tab = 0


func _on_new_chat_pressed() -> void:
	if chat_tab_bar == null:
		return
	var idx := _chats.size() + 1
	var title := "Chat %d" % idx
	_chats.append({"title": title, "messages": [], "context_usage": {}, "prompt_draft": "", "current_activity": {}, "activity_history": []})
	chat_tab_bar.add_tab(title)
	_current_chat = _chats.size() - 1
	chat_tab_bar.current_tab = _current_chat
	_streamed_markdown = ""
	_ensure_chat_has_messages()
	_update_context_usage_label()
	_render_chat_log()


func _on_chat_tab_selected(tab_index: int) -> void:
	if tab_index < 0 or tab_index >= _chats.size():
		return
	# Save current chat's prompt draft and activity before switching
	if _current_chat >= 0 and _current_chat < _chats.size():
		var cur: Dictionary = _chats[_current_chat]
		if not cur.has("prompt_draft"):
			cur["prompt_draft"] = ""
		cur["prompt_draft"] = prompt_text_edit.text if prompt_text_edit else ""
		cur["current_activity"] = _current_activity.duplicate()
		cur["activity_history"] = _activity_history.duplicate()
	_current_chat = tab_index
	_ensure_chat_has_messages()
	var chat: Dictionary = _chats[tab_index]
	# Restore prompt and activity for the selected chat
	if prompt_text_edit:
		prompt_text_edit.text = chat.get("prompt_draft", "")
	_current_activity = (chat.get("current_activity", {}) as Dictionary).duplicate()
	_activity_history = (chat.get("activity_history", []) as Array).duplicate()
	var messages: Array = chat.get("messages", [])
	_streamed_markdown = ""
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		_streamed_markdown = messages[messages.size() - 1].get("text", "")
	_update_activity_ui()
	_render_chat_log()
	_update_context_usage_label()
	_update_tool_calls_ui()


func _on_chat_tab_rearranged(_idx_to: int) -> void:
	# TabBar has already reordered its tabs; sync _chats to match the new tab order.
	if chat_tab_bar == null or _chats.size() != chat_tab_bar.tab_count:
		return
	var new_chats: Array = []
	for i in range(chat_tab_bar.tab_count):
		var title := chat_tab_bar.get_tab_title(i)
		for c in _chats:
			if typeof(c) == TYPE_DICTIONARY and str(c.get("title", "")) == title:
				new_chats.append(c)
				break
	if new_chats.size() == _chats.size():
		_chats = new_chats
		_current_chat = chat_tab_bar.current_tab
		if _current_chat >= 0 and _current_chat < _chats.size():
			_render_chat_log()
			_update_context_usage_label()


func _on_main_tab_changed(tab_index: int) -> void:
	# Use child name so behavior is correct after user drag-reorders main tabs.
	if tab_container and tab_index >= 0 and tab_index < tab_container.get_child_count():
		var child: Node = tab_container.get_child(tab_index)
		var name_str := child.name if child else ""
		if name_str == "Settings":
			_refresh_settings_tab_from_config()
		elif name_str == "History":
			_refresh_history()


func _on_history_refresh_pressed() -> void:
	_refresh_history()


func _refresh_history() -> void:
	var data := await _query_backend_json("%s/edit_events/list?limit=500" % rag_service_url, HTTPClient.METHOD_GET, "")
	if typeof(data) != TYPE_DICTIONARY:
		return
	var events = data.get("events", [])
	if events is Array:
		_history_events = events
	_render_history_list()


func _render_history_list() -> void:
	if not history_list:
		return
	history_list.clear()
	_selected_history_edit_id = -1
	if history_detail_label:
		history_detail_label.text = ""
	for e in _history_events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id_val := int(e.get("id", -1))
		var summary := str(e.get("summary", ""))
		var trigger := str(e.get("trigger", ""))
		var ts := float(e.get("timestamp", 0.0))
		var time_str := Time.get_datetime_string_from_unix_time(int(ts)) if ts > 0 else ""
		var changes = e.get("changes", [])
		var add_total := 0
		var rem_total := 0
		var file_count := 0
		if changes is Array:
			file_count = changes.size()
			for c in changes:
				if typeof(c) == TYPE_DICTIONARY:
					add_total += int(c.get("lines_added", 0))
					rem_total += int(c.get("lines_removed", 0))
		var time_part := ("[%s]  " % time_str) if not time_str.is_empty() else ""
		var label := "%s#%d  %d file(s)  [+%d -%d]  %s  (%s)" % [time_part, id_val, file_count, add_total, rem_total, summary, trigger]
		history_list.add_item(label)


func _on_history_item_selected(index: int) -> void:
	if index < 0 or index >= _history_events.size():
		return
	var e = _history_events[index]
	if typeof(e) != TYPE_DICTIONARY:
		return
	_selected_history_edit_id = int(e.get("id", -1))
	if history_detail_label:
		history_detail_label.text = ""
		var parts: Array[String] = []
		parts.append("[b]Edit #%d[/b]\n" % _selected_history_edit_id)
		var ts := float(e.get("timestamp", 0.0))
		if ts > 0:
			parts.append("[b]Timestamp:[/b] %s\n" % Time.get_datetime_string_from_unix_time(int(ts)))
		parts.append("[b]Summary:[/b] %s\n" % str(e.get("summary", "")))
		parts.append("[b]Trigger:[/b] %s\n" % str(e.get("trigger", "")))
		var changes = e.get("changes", [])
		if changes is Array and changes.size() > 0:
			parts.append("\n[b]Files changed:[/b]")
			for c in changes:
				if typeof(c) != TYPE_DICTIONARY:
					continue
				var fp := str(c.get("file_path", ""))
				var ct := str(c.get("change_type", "modify"))
				var add_n := int(c.get("lines_added", 0))
				var rem_n := int(c.get("lines_removed", 0))
				parts.append("\n  • %s  (%s)  [+%d -%d]" % [fp, ct, add_n, rem_n])
				var diff := str(c.get("diff", ""))
				if not diff.is_empty():
					parts.append("\n  [code]" + _escape_bbcode(diff) + "[/code]")
			parts.append("")
		var prompt_text := str(e.get("prompt", ""))
		if not prompt_text.is_empty():
			parts.append("\n[b]Prompt:[/b]\n[code]" + _escape_bbcode(prompt_text) + "[/code]\n")
		var semantic := str(e.get("semantic_summary", ""))
		if not semantic.is_empty():
			parts.append("\n[b]Summary (AI):[/b] %s\n" % _escape_bbcode(semantic))
		var lint_before := str(e.get("lint_errors_before", ""))
		if not lint_before.is_empty():
			parts.append("\n[b]Lint before:[/b]\n[code]" + _escape_bbcode(lint_before) + "[/code]\n")
		var lint_after := str(e.get("lint_errors_after", ""))
		if not lint_after.is_empty():
			parts.append("\n[b]Lint after:[/b]\n[code]" + _escape_bbcode(lint_after) + "[/code]\n")
		history_detail_label.bbcode_enabled = true
		history_detail_label.text = "\n".join(parts)


func _on_history_undo_pressed() -> void:
	if _selected_history_edit_id < 0:
		return
	var endpoint := "%s/edit_events/undo/%d" % [rag_service_url, _selected_history_edit_id]
	var data := await _query_backend_json(endpoint, HTTPClient.METHOD_POST, "{}")
	if typeof(data) != TYPE_DICTIONARY:
		return
	var tool_calls = data.get("tool_calls", [])
	if tool_calls is Array and tool_calls.size() > 0 and _tool_executor:
		await _run_editor_actions_async(tool_calls, false, "undo", "Undo edit #%d" % _selected_history_edit_id)
		_refresh_history()


func _query_backend_json(endpoint: String, method: int, body: String) -> Variant:
	var client := HTTPClient.new()
	var scheme_split := endpoint.split("://")
	var remainder := scheme_split[1] if scheme_split.size() == 2 else endpoint
	var first_slash := remainder.find("/")
	var host_port := remainder if first_slash == -1 else remainder.substr(0, first_slash)
	var path := "/" if first_slash == -1 else remainder.substr(first_slash)
	var host := host_port
	var port := 80
	var colon_index := host_port.find(":")
	if colon_index != -1:
		host = host_port.substr(0, colon_index)
		port = int(host_port.substr(colon_index + 1))

	var err := client.connect_to_host(host, port)
	if err != OK:
		return null
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return null

	var headers := PackedStringArray(["Content-Type: application/json"])
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Length: %d" % body.to_utf8_buffer().size())
		client.request(method, path, headers, body)
	else:
		client.request(method, path, headers, "")

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_BODY:
		return null

	var response_bytes := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			response_bytes.append_array(chunk)
		await get_tree().process_frame

	var body_text := response_bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(body_text) != OK:
		return null
	return json.data


func _refresh_settings_tab_from_config() -> void:
	if _settings == null:
		return
	_settings.load_settings()
	if settings_text_size_spin:
		settings_text_size_spin.value = _settings.text_size
	if settings_word_wrap_check:
		settings_word_wrap_check.button_pressed = _settings.word_wrap
	if settings_rag_url_edit:
		settings_rag_url_edit.text = _settings.rag_service_url
	if settings_api_key_edit:
		settings_api_key_edit.text = _settings.openai_api_key
	if settings_base_url_edit:
		settings_base_url_edit.text = _settings.openai_base_url
	if settings_model_option:
		settings_model_option.clear()
		for i in range(_settings.get_openai_models().size()):
			var m: String = _settings.get_openai_models()[i]
			settings_model_option.add_item(m, i)
		var idx: int = _settings.get_openai_models().find(_settings.selected_model)
		if idx >= 0:
			settings_model_option.select(idx)
		else:
			settings_model_option.select(0)
	_refresh_index_and_context_status()


func _refresh_index_and_context_status() -> void:
	_update_context_windows_ui()
	if not index_status_request:
		return
	var base := (settings_rag_url_edit.text if settings_rag_url_edit else rag_service_url).strip_edges()
	if base.is_empty():
		base = rag_service_url
	var project_root := ProjectSettings.globalize_path("res://").strip_edges()
	var url := base + "/index_status"
	if not project_root.is_empty():
		url += "?project_root=" + project_root.uri_encode()
	indexing_content.text = "Loading..."
	index_status_request.request(url)


func _on_index_status_request_completed(_result: int, _response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var json_str := body.get_string_from_utf8()
	if json_str.is_empty():
		if indexing_content:
			indexing_content.text = "Could not reach backend."
		return
	var j := JSON.new()
	if j.parse(json_str) != OK:
		if indexing_content:
			indexing_content.text = "Invalid response."
		return
	var d = j.data
	if typeof(d) != TYPE_DICTIONARY:
		if indexing_content:
			indexing_content.text = "Invalid response."
		return
	var lines: Array[String] = []
	lines.append("Chroma docs: %d chunks" % int(d.get("chroma_docs", 0)))
	lines.append("Chroma project_code: %d snippets" % int(d.get("chroma_project_code", 0)))
	var repo_err = d.get("repo_index_error", null)
	if repo_err != null and str(repo_err).strip_edges().length() > 0:
		lines.append("Repo index: %s" % str(repo_err))
	elif d.get("repo_index_files", null) != null:
		lines.append("Repo index: %d files, %d edges" % [int(d.get("repo_index_files", 0)), int(d.get("repo_index_edges", 0))])
	else:
		lines.append("Repo index: (send project_root for stats)")
	if indexing_content:
		indexing_content.text = "\n".join(lines)
	_update_context_windows_ui()


func _update_context_windows_ui() -> void:
	if not context_windows_list:
		return
	for c in context_windows_list.get_children():
		c.queue_free()
	for i in range(_chats.size()):
		var chat: Dictionary = _chats[i]
		var title: String = chat.get("title", "Chat %d" % (i + 1))
		var messages: Array = chat.get("messages", [])
		var usage: Dictionary = chat.get("context_usage", {})
		var est: int = int(usage.get("estimated_prompt_tokens", 0))
		var limit: int = int(usage.get("limit_tokens", 0))
		var pct: float = float(usage.get("percent", 0.0))
		var usage_str := "—"
		if limit > 0 and est > 0:
			usage_str = "%d tokens (~%d%%)" % [est, int(pct * 100.0)]
		elif est > 0:
			usage_str = "%d tokens" % est
		var line := "%s: %d messages, %s" % [title, messages.size(), usage_str]
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", 12)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		context_windows_list.add_child(l)


func _save_settings_tab_to_config() -> void:
	if _settings == null:
		return
	if settings_text_size_spin:
		_settings.text_size = int(settings_text_size_spin.value)
	if settings_word_wrap_check:
		_settings.word_wrap = settings_word_wrap_check.button_pressed
	if settings_rag_url_edit:
		_settings.rag_service_url = settings_rag_url_edit.text.strip_edges()
	if settings_api_key_edit:
		_settings.openai_api_key = settings_api_key_edit.text
	if settings_base_url_edit:
		_settings.openai_base_url = settings_base_url_edit.text.strip_edges()
	if settings_model_option and settings_model_option.selected >= 0:
		var models: Array[String] = _settings.get_openai_models()
		if settings_model_option.selected < models.size():
			_settings.selected_model = models[settings_model_option.selected]
	_settings.save_settings()


func _on_settings_save_pressed() -> void:
	_save_settings_tab_to_config()
	_apply_settings_from_config()
	if tab_container:
		tab_container.current_tab = 0
	_set_status("Settings saved.")


func _on_refresh_indicators_pressed() -> void:
	if _decorator:
		_decorator.debug_diagnostic = true
		_decorator.apply_decorations()
		_decorator.debug_diagnostic = false
		_set_status("Indicators refreshed. See Output for diagnostic.")
	else:
		_set_status("Decorator not available.")


func _apply_settings_from_config() -> void:
	if _settings == null:
		return
	_settings.load_settings()
	rag_service_url = _settings.rag_service_url
	if follow_agent_check:
		follow_agent_check.button_pressed = _settings.follow_agent
	if allow_editor_actions_check:
		allow_editor_actions_check.button_pressed = _settings.allow_editor_actions
	if model_option:
		model_option.clear()
		for i in range(_settings.get_openai_models().size()):
			var m: String = _settings.get_openai_models()[i]
			model_option.add_item(m, i)
		var idx: int = _settings.get_openai_models().find(_settings.selected_model)
		if idx >= 0:
			model_option.select(idx)
		else:
			model_option.select(0)
	_apply_display_settings()


func _apply_display_settings() -> void:
	if _settings == null:
		return
	var font_size: int = _settings.text_size
	if output_text_edit:
		output_text_edit.add_theme_font_size_override("normal_font_size", font_size)
		output_text_edit.add_theme_font_size_override("mono_font_size", font_size)
		output_text_edit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if _settings.word_wrap else TextServer.AUTOWRAP_OFF
	if prompt_text_edit:
		prompt_text_edit.add_theme_font_size_override("font_size", font_size)
		prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if _settings.word_wrap else TextEdit.LINE_WRAPPING_NONE


func _on_model_selected(_index: int) -> void:
	if _settings and model_option and model_option.selected >= 0:
		var models: Array[String] = _settings.get_openai_models()
		if model_option.selected < models.size():
			_settings.selected_model = models[model_option.selected]
			_settings.save_settings()


func _on_follow_agent_toggled(_pressed: bool) -> void:
	if _settings and follow_agent_check:
		_settings.follow_agent = follow_agent_check.button_pressed
		_settings.save_settings()


func _on_allow_editor_actions_toggled(_pressed: bool) -> void:
	if _settings and allow_editor_actions_check:
		_settings.allow_editor_actions = allow_editor_actions_check.button_pressed
		_settings.save_settings()


func _start_health_check() -> void:
	if not http_request:
		return
	var url: String = "%s/health" % rag_service_url
	_pending_http_kind = &"health"
	_set_status("Checking backend...")
	var err := http_request.request(url)
	if err != OK:
		_set_status("Failed to start health check.")
		_pending_http_kind = &""
