@tool
extends Control
class_name GodotAIDock

@onready var tab_container: TabContainer = $TabContainer
@onready var chat_tab_bar: TabBar = $TabContainer/Chat/VBox/ChatTabBarRow/ChatTabBar
@onready var context_usage_label: Label = $TabContainer/Chat/VBox/ChatTabBarRow/ContextUsageLabel
@onready var new_chat_button: Button = $TabContainer/Chat/VBox/ChatTabBarRow/NewChatButton
@onready var settings_button: Button = $TabContainer/Chat/VBox/ChatTabBarRow/SettingsButton
@onready var output_text_edit: RichTextLabel = $TabContainer/Chat/VBox/IOContainer/OutputText
@onready var prompt_text_edit: TextEdit = $TabContainer/Chat/VBox/IOContainer/PromptTextEdit
@onready var model_option: OptionButton = $TabContainer/Chat/VBox/BottomRow/ModelOption
@onready var ask_button: Button = $TabContainer/Chat/VBox/BottomRow/AskButton
@onready var copy_button: Button = $TabContainer/Chat/VBox/BottomRow/CopyButton
@onready var follow_agent_check: CheckButton = $TabContainer/Chat/VBox/BottomRow/FollowAgentCheck
@onready var allow_editor_actions_check: CheckButton = $TabContainer/Chat/VBox/BottomRow/AllowEditorActionsCheck
@onready var status_label: Label = $TabContainer/Chat/VBox/BottomRow/StatusLabel
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
var _history_events: Array = []
var _selected_history_edit_id: int = -1
var _last_context_usage: Dictionary = {}
var _ask_icon_idle: Texture2D = null
var _ask_icon_busy: Texture2D = null
var _selected_pending_id: String = ""
var _selected_timeline_id: String = ""
var _last_tool_prompt: String = ""
var _last_tool_trigger: String = "tool_action"
var _decoration_timer: Timer = null

# Each chat: { title: String, messages: Array } where each message is { role: "user"|"assistant", text: String }
var _chats: Array = []
var _current_chat: int = -1
const _SCROLL_AT_BOTTOM_THRESHOLD: float = 25.0


func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e
	_tool_executor = GodotAIEditorToolExecutor.new(e) if e else null
	_settings = GodotAISettings.new()
	_settings.set_editor_interface(e)
	_edit_store = GodotAIEditStore.new()
	_edit_store.load_from_disk()
	if _editor_interface:
		var base := _editor_interface.get_base_control()
		if base:
			_ask_icon_idle = base.get_theme_icon("Play", "EditorIcons")
			_ask_icon_busy = base.get_theme_icon("Reload", "EditorIcons")


func _ready() -> void:
	print("AI Assistant: _ready called on dock")
	if output_text_edit:
		output_text_edit.bbcode_enabled = true
	if ask_button:
		ask_button.text = ""
		ask_button.flat = false
		ask_button.custom_minimum_size = Vector2(32, 32)
		ask_button.pressed.connect(_on_ask_button_pressed)
		_update_ask_button_state()
	else:
		print("AI Assistant: ask_button is null")

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
		chat_tab_bar.tab_selected.connect(_on_chat_tab_selected)
	if settings_button:
		settings_button.pressed.connect(_on_settings_pressed)
	if model_option:
		model_option.item_selected.connect(_on_model_selected)
	if follow_agent_check:
		follow_agent_check.toggled.connect(_on_follow_agent_toggled)
	if allow_editor_actions_check:
		allow_editor_actions_check.toggled.connect(_on_allow_editor_actions_toggled)
	if tab_container:
		tab_container.tab_changed.connect(_on_main_tab_changed)
	if settings_save_button:
		settings_save_button.pressed.connect(_on_settings_save_pressed)
	if history_refresh_button:
		history_refresh_button.pressed.connect(_on_history_refresh_pressed)
	if history_list:
		history_list.item_selected.connect(_on_history_item_selected)
	if history_undo_button:
		history_undo_button.pressed.connect(_on_history_undo_pressed)

	if pending_list:
		pending_list.item_selected.connect(_on_pending_item_selected)
	if pending_accept_button:
		pending_accept_button.pressed.connect(_on_pending_accept_pressed)
	if pending_reject_button:
		pending_reject_button.pressed.connect(_on_pending_reject_pressed)
	if timeline_list:
		timeline_list.item_selected.connect(_on_timeline_item_selected)

	_apply_settings_from_config()
	_update_context_usage_label()
	_ensure_default_chat()
	_refresh_settings_tab_from_config()
	_start_health_check()
	_render_changes_tab()
	_apply_editor_decorations()
	_start_decoration_refresh()


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


func _on_ask_button_pressed() -> void:
	print("AI Assistant: Ask button pressed")
	_ensure_default_chat()
	var question: String = prompt_text_edit.text.strip_edges()
	if question.is_empty():
		status_label.text = "Please enter a question."
		return

	# Remember the originating prompt so any subsequent tool-driven edits can be logged server-side.
	_last_tool_prompt = question
	_last_tool_trigger = "tool_action"

	if prompt_text_edit:
		prompt_text_edit.text = ""

	status_label.text = "Sending request to RAG service..."
	output_text_edit.clear()

	_ensure_chat_has_messages()
	_chats[_current_chat]["messages"].append({"role": "user", "text": question})
	_chats[_current_chat]["messages"].append({"role": "assistant", "text": ""})
	_streamed_markdown = ""

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
		status_label.text = "Request failed: %d" % result
		_pending_http_kind = &""
		return

	if response_code < 200 or response_code >= 300:
		status_label.text = "HTTP error: %d" % response_code
		_pending_http_kind = &""
		return

	var body_text: String = body.get_string_from_utf8()
	print("AI Assistant: response body: ", body_text)

	var json := JSON.new()
	var parse_result: int = json.parse(body_text)
	if parse_result != OK:
		status_label.text = "Failed to parse JSON response."
		_pending_http_kind = &""
		return

	var data := json.data
	if typeof(data) != TYPE_DICTIONARY:
		status_label.text = "Unexpected response format."
		_pending_http_kind = &""
		return

	if _pending_http_kind == &"health":
		var status_val: Variant = data.get("status", "")
		if typeof(status_val) == TYPE_STRING and String(status_val) == "ok":
			status_label.text = "Backend ready."
		else:
			status_label.text = "Backend reachable, unexpected /health response."
		_pending_http_kind = &""
		return

	if _pending_http_kind == &"query":
		_pending_http_kind = &""
		var answer: String = data.get("answer", "")
		var usage_raw = data.get("context_usage", null)
		if typeof(usage_raw) == TYPE_DICTIONARY:
			_last_context_usage = usage_raw
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
		status_label.text = "Response received."
		if tool_calls_raw is Array and tool_calls_raw.size() > 0 and _tool_executor:
			_run_editor_actions_async(tool_calls_raw, true, "tool_action", _last_tool_prompt)
		return

	_pending_http_kind = &""


func _on_copy_button_pressed() -> void:
	if not output_text_edit:
		return
	var text_to_copy := output_text_edit.get_parsed_text()
	if text_to_copy.is_empty():
		status_label.text = "Nothing to copy."
		return
	DisplayServer.clipboard_set(text_to_copy)
	status_label.text = "Copied answer to clipboard."


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
		status_label.text = "Failed to connect to RAG service."
		return

	_stream_http(client, path, body)


func _stream_http(client: HTTPClient, path: String, body: String) -> void:
	await get_tree().process_frame

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		status_label.text = "Failed to connect to RAG service."
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
		status_label.text = "Unexpected HTTP status."
		_streaming_in_progress = false
		_update_ask_button_state()
		return

	status_label.text = "Receiving response..."

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
		_streamed_markdown += delta
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] = _streamed_markdown
		_render_chat_log()
		await get_tree().process_frame

	# Parse trailing __TOOL_CALLS__ from query_stream_with_tools and run editor actions.
	const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
	const USAGE_MARKER := "\n__USAGE__\n"
	var marker_pos := _streamed_markdown.find(TOOL_CALLS_MARKER)
	if marker_pos >= 0:
		var display_text := _streamed_markdown.substr(0, marker_pos)
		var tail := _streamed_markdown.substr(marker_pos + TOOL_CALLS_MARKER.length())
		var usage_pos := tail.find(USAGE_MARKER)
		var tool_calls_json := tail.strip_edges()
		var usage_json := ""
		if usage_pos >= 0:
			tool_calls_json = tail.substr(0, usage_pos).strip_edges()
			usage_json = tail.substr(usage_pos + USAGE_MARKER.length()).strip_edges()
		_streamed_markdown = display_text
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] = display_text
		_render_chat_log()
		if not tool_calls_json.is_empty():
			var json := JSON.new()
			if json.parse(tool_calls_json) == OK and json.data is Array:
				_run_editor_actions_async(json.data, true, "tool_action", _last_tool_prompt)
		if not usage_json.is_empty():
			var uj := JSON.new()
			if uj.parse(usage_json) == OK and uj.data is Dictionary:
				_last_context_usage = uj.data
				_update_context_usage_label()

	_streaming_in_progress = false
	_update_ask_button_state()
	status_label.text = "Response received."


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
	if _last_context_usage.is_empty():
		context_usage_label.text = "Ctx: --"
		return
	var est := int(_last_context_usage.get("estimated_prompt_tokens", 0))
	var limit := int(_last_context_usage.get("limit_tokens", 0))
	var pct := float(_last_context_usage.get("percent", 0.0))
	if limit > 0:
		context_usage_label.text = "Ctx: %d%% (%d/%d)" % [int(pct * 100.0), est, limit]
	else:
		context_usage_label.text = "Ctx: %d" % est


func _escape_bbcode(t: String) -> String:
	return t.replace("[", "[[")  # RichTextLabel uses [[ for literal [


func _render_chat_log() -> void:
	if not output_text_edit:
		return
	_ensure_chat_has_messages()
	var messages: Array = _chats[_current_chat]["messages"]
	var parts: Array[String] = []
	var width := int(output_text_edit.size.x)
	# Rough char-per-line estimate to make a "full width" divider in BBCode.
	# (Godot RichTextLabel BBCode doesn't have a true [hr] tag.)
	var font_size := int(output_text_edit.get_theme_font_size("normal_font_size"))
	if font_size <= 0:
		font_size = 14
	var approx_char_px := max(6.0, float(font_size) * 0.60)
	var divider_chars := max(24, int(float(width) / approx_char_px))
	var divider := "─".repeat(divider_chars)
	for msg in messages:
		var role: String = msg.get("role", "assistant")
		var text: String = msg.get("text", "")
		if role == "user":
			parts.append("[right]" + _escape_bbcode(text) + "[/right]")
		else:
			parts.append(_markdown_renderer.markdown_to_bbcode(text))
		# Low opacity divider spanning the visible width.
		parts.append("[color=#55555588]" + divider + "[/color]\n")
	var bbcode: String = "\n".join(parts)
	var was_at_bottom: bool = _is_output_at_bottom()
	output_text_edit.clear()
	output_text_edit.text = bbcode
	if was_at_bottom:
		output_text_edit.scroll_to_line(max(output_text_edit.get_line_count() - 1, 0))


func _is_output_at_bottom() -> bool:
	if not output_text_edit:
		return true
	var vbar: VScrollBar = output_text_edit.get_v_scroll_bar()
	if vbar == null:
		return true
	return (vbar.max_value - vbar.value) <= _SCROLL_AT_BOTTOM_THRESHOLD


func _update_output_from_markdown() -> void:
	_render_chat_log()


func _run_editor_actions_async(tool_calls: Array, proposal_mode: bool, trigger: String = "", prompt: String = "") -> void:
	var results: Array[String] = []
	if _tool_executor:
		_tool_executor.set_follow_agent(follow_agent_check.button_pressed if follow_agent_check else false)
	var edit_records: Array = []
	var effective_trigger := trigger if not trigger.is_empty() else _last_tool_trigger
	var effective_prompt := prompt if not prompt.is_empty() else _last_tool_prompt
	for tc in tool_calls:
		if typeof(tc) != TYPE_DICTIONARY:
			continue
		var out = tc.get("output", {})
		if typeof(out) != TYPE_DICTIONARY or not out.get("execute_on_client", false):
			continue
		var action: String = str(out.get("action", ""))
		# For file edits, create a pending change proposal with diff preview + accept/reject.
		if proposal_mode and action in ["create_file", "write_file", "apply_patch", "create_script", "delete_file"]:
			if _edit_store and _tool_executor:
				var prev = _tool_executor.preview_file_change(out)
				if prev.get("ok", false):
					var change: Dictionary = prev.get("change", {})
					_edit_store.add_pending_file_change(change)
					results.append("Proposed: %s" % str(change.get("summary", action)))
				else:
					results.append("Error: %s" % str(prev.get("message", "preview failed")))
			continue
		elif not proposal_mode and action in ["create_file", "write_file", "apply_patch", "create_script", "delete_file"]:
			status_label.text = "Applying editor action: %s..." % action
			var file_result: Dictionary = await _tool_executor.execute_async(out)
			if file_result.get("success", false):
				results.append(file_result.get("message", "OK"))
			else:
				results.append("Error: %s" % file_result.get("message", "unknown"))
			var rec2 := file_result.get("edit_record", null)
			if rec2 != null:
				edit_records.append(rec2)
			continue

		# Node edits are applied immediately (but still tracked).
		status_label.text = "Running editor action: %s..." % action
		var result: Dictionary = await _tool_executor.execute_async(out)
		if result.get("success", false):
			results.append(result.get("message", "OK"))
		else:
			results.append("Error: %s" % result.get("message", "unknown"))

		var rec := result.get("edit_record", null)
		if rec != null:
			edit_records.append(rec)

		# Track node changes for scene tree indicators.
		if _edit_store and result.get("success", false):
			if action == "create_node":
				var scene_path := str(out.get("scene_path", ""))
				var parent_path := str(out.get("parent_path", ""))
				var node_name := str(out.get("node_name", ""))
				var node_type := str(out.get("node_type", "Node"))
				var name := node_name if not node_name.is_empty() else node_type
				var node_path := name
				if not parent_path.is_empty() and parent_path != "/root" and parent_path != "/":
					node_path = parent_path.trim_prefix("/root/").trim_prefix("/").path_join(name)
				_edit_store.add_node_change(scene_path, node_path, "created", "create node %s" % node_path)
			elif action == "set_node_property":
				var scene_path2 := str(out.get("scene_path", ""))
				var node_path2 := str(out.get("node_path", ""))
				var prop := str(out.get("property_name", ""))
				# Normalize to a /-separated path without /root prefix.
				var normalized := node_path2.trim_prefix("/root/").trim_prefix("/")
				_edit_store.add_node_change(scene_path2, normalized, "modified", "set %s.%s" % [normalized, prop])

	if edit_records.size() > 0:
		await _log_edit_event_to_backend(edit_records, effective_trigger, effective_prompt)
	if results.size() > 0:
		status_label.text = "Editor actions: %s" % ", ".join(results)
		var section: String = "\n\n--- Editor actions ---\n" + "\n".join(results)
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] += section
		_render_chat_log()
	else:
		status_label.text = "Response received."

	_render_changes_tab()
	_apply_editor_decorations()


func _render_changes_tab() -> void:
	if _edit_store == null:
		return
	if pending_list:
		pending_list.clear()
		_selected_pending_id = ""
		for p in _edit_store.pending:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var marker = _edit_store.get_file_marker(str(p.get("file_path", "")))
			var label := "%s%s" % [marker, str(p.get("summary", ""))]
			pending_list.add_item(label)
	if timeline_list:
		timeline_list.clear()
		_selected_timeline_id = ""
		for e in _edit_store.events:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var kind = str(e.get("kind", ""))
			var label := ""
			if kind == "file":
				var fp = str(e.get("file_path", ""))
				var marker = _edit_store.get_file_marker(fp)
				label = "%s%s" % [marker, str(e.get("summary", ""))]
			else:
				label = "🧩 %s" % str(e.get("summary", "node change"))
			timeline_list.add_item(label)


func _show_diff(old_content: String, new_content: String) -> void:
	if diff_old_text:
		diff_old_text.text = old_content
	if diff_new_text:
		diff_new_text.text = new_content


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


func _on_pending_accept_pressed() -> void:
	if _edit_store == null or _tool_executor == null:
		return
	if _selected_pending_id.is_empty():
		return
	var p = _edit_store.accept_pending(_selected_pending_id)
	if p.is_empty():
		return
	var path := str(p.get("file_path", ""))
	var new_content := str(p.get("new_content", ""))
	var apply_action := str(p.get("apply_action", ""))
	var apply_out: Dictionary
	if apply_action == "delete_file" or str(p.get("change_type", "")) == "delete":
		apply_out = {"execute_on_client": true, "action": "delete_file", "path": path}
	else:
		apply_out = {"execute_on_client": true, "action": "write_file", "path": path, "content": new_content}
	var result: Dictionary = _tool_executor.execute(apply_out)
	var lint_ok := true
	if result.get("success", false) and _should_lint_path(path):
		lint_ok = await _lint_and_autofix_return_ok(path, 5)
	if _edit_store:
		_edit_store.add_applied_file_change({
			"id": str(p.get("id", "")),
			"created_unix": int(p.get("created_unix", Time.get_unix_time_from_system())),
			"file_path": path,
			"change_type": str(p.get("change_type", "modify")),
			"summary": str(p.get("summary", "")),
			"old_content": str(p.get("old_content", "")),
			"new_content": new_content,
		}, lint_ok)
	_render_changes_tab()
	_apply_editor_decorations()


func _on_pending_reject_pressed() -> void:
	if _edit_store == null:
		return
	if _selected_pending_id.is_empty():
		return
	_edit_store.reject_pending(_selected_pending_id)
	_selected_pending_id = ""
	_show_diff("", "")
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
	var project_dir := ProjectSettings.globalize_path("res://")
	var rel_path := res_path
	if rel_path.begins_with("res://"):
		rel_path = rel_path.substr("res://".length())

	var original_before_any_fix := _read_text_res(res_path)
	var first_failure_output := ""

	for attempt in range(max_rounds):
		var lint := _run_headless_lint(project_dir, rel_path)
		var ok: bool = lint.get("ok", false)
		if ok:
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
		var fix_question := (
			"Fix the lint errors in this file and only change what is necessary.\n"
			+ "File: %s\n"
			+ "Project root: res://\n"
			+ "Lint output:\n%s\n\n"
			+ "Use editor tools (apply_patch or write_file) to update the file.\n"
			+ "After making edits, assume lint will be rerun; keep iterating until it passes."
		) % [res_path, lint_output]
		var fix_resp := await _query_backend_for_tools(fix_question, lint_output)
		var tool_calls := fix_resp.get("tool_calls", [])
		if tool_calls is Array and tool_calls.size() > 0 and _tool_executor:
			await _run_editor_actions_async(tool_calls, false, "lint_fix", fix_question)
		else:
			_post_system_message(
				("Auto-lint failed on %s (attempt %d/%d), but the backend did not return any tool calls to fix it.\n\nLint output:\n%s")
				% [res_path, attempt + 1, max_rounds, lint_output]
			)
			return false
	var final_lint := _run_headless_lint(project_dir, rel_path)
	return bool(final_lint.get("ok", false))


func _apply_editor_decorations() -> void:
	if _editor_interface == null or _edit_store == null:
		return
	var base := _editor_interface.get_base_control()
	if base == null:
		return
	_decorate_script_tabs(base)
	_decorate_filesystem_tree(base)
	_decorate_scene_tree(base)


func _strip_markers(s: String) -> String:
	return s.trim_prefix("🟢 ").trim_prefix("🟡 ").trim_prefix("🔴 ").trim_prefix("⚫ ").trim_prefix("🧩 ")


func _decorate_script_tabs(base: Control) -> void:
	var tab_bar := base.find_child("ScriptEditorTabBar", true, false)
	if tab_bar == null:
		# Fallback: find first TabBar under ScriptEditor.
		var script_editor := _editor_interface.get_script_editor() if _editor_interface else null
		if script_editor:
			tab_bar = (script_editor as Node).find_child("TabBar", true, false)
	if tab_bar == null or not (tab_bar is TabBar):
		return
	var tb: TabBar = tab_bar
	for i in range(tb.tab_count):
		var title := tb.get_tab_title(i)
		var raw := _strip_markers(title)
		# Best-effort: match against open script name by checking editor resources.
		var marker = ""
		if _edit_store:
			# Prefer direct resource path if title contains .gd/.cs etc.
			var lower := raw.to_lower()
			if lower.find(".gd") != -1 or lower.find(".cs") != -1 or lower.find(".gdshader") != -1:
				# Not a full res:// path; try to locate by suffix.
				for fp in _edit_store.file_status.keys():
					if str(fp).to_lower().ends_with(lower):
						marker = _edit_store.get_file_marker(str(fp))
						break
		tb.set_tab_title(i, marker + raw)


func _decorate_filesystem_tree(base: Control) -> void:
	var fsdock := base.find_child("FileSystemDock", true, false)
	if fsdock == null:
		fsdock = base.find_child("FileSystem", true, false)
	if fsdock == null:
		return
	var tree_node := (fsdock as Node).find_child("Tree", true, false)
	if tree_node == null or not (tree_node is Tree):
		return
	var tree: Tree = tree_node
	var root := tree.get_root()
	if root == null:
		return
	_decorate_tree_items_files(root)


func _decorate_tree_items_files(item: TreeItem) -> void:
	while item:
		var text := item.get_text(0)
		var raw := _strip_markers(text)
		var md := item.get_metadata(0)
		var marker = ""
		if typeof(md) == TYPE_STRING:
			marker = _edit_store.get_file_marker(str(md))
		else:
			# Fallback: suffix match.
			for fp in _edit_store.file_status.keys():
				if str(fp).to_lower().ends_with(raw.to_lower()):
					marker = _edit_store.get_file_marker(str(fp))
					break
		item.set_text(0, marker + raw)
		if item.get_first_child():
			_decorate_tree_items_files(item.get_first_child())
		item = item.get_next()


func _decorate_scene_tree(base: Control) -> void:
	var scenedock := base.find_child("SceneTreeDock", true, false)
	if scenedock == null:
		scenedock = base.find_child("Scene", true, false)
	if scenedock == null:
		return
	var tree_node := (scenedock as Node).find_child("SceneTreeEditor", true, false)
	if tree_node == null:
		tree_node = (scenedock as Node).find_child("Tree", true, false)
	if tree_node == null:
		return
	var tree := tree_node.find_child("Tree", true, false) if tree_node is Node else null
	if tree == null and tree_node is Tree:
		tree = tree_node
	if tree == null or not (tree is Tree):
		return
	var scene_root := _editor_interface.get_edited_scene_root()
	var scene_path := scene_root.scene_file_path if scene_root else ""
	if scene_path.is_empty():
		return
	var root := (tree as Tree).get_root()
	if root == null:
		return
	_decorate_tree_items_nodes(root, scene_path, "")


func _decorate_tree_items_nodes(item: TreeItem, scene_path: String, parent_path: String) -> void:
	while item:
		var text := item.get_text(0)
		var raw := _strip_markers(text)
		var my_path := raw if parent_path.is_empty() else parent_path + "/" + raw
		var marker = _edit_store.get_node_marker(scene_path, my_path)
		item.set_text(0, marker + raw)
		if item.get_first_child():
			_decorate_tree_items_nodes(item.get_first_child(), scene_path, my_path)
		item = item.get_next()


func _log_edit_event_to_backend(edit_records: Array, trigger: String = "tool_action", prompt: String = "") -> void:
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
	# NOTE: This lints by launching the editor binary in headless+editor mode.
	# It then asks the backend to fix any lint output and retries.
	var project_dir := ProjectSettings.globalize_path("res://")
	var rel_path := res_path
	if rel_path.begins_with("res://"):
		rel_path = rel_path.substr("res://".length())

	for attempt in range(max_rounds):
		var lint := _run_headless_lint(project_dir, rel_path)
		var ok: bool = lint.get("ok", false)
		if ok:
			return

		var lint_output: String = str(lint.get("output", "")).strip_edges()
		if lint_output.is_empty():
			lint_output = "Lint failed but produced no output."

		# Ask backend to fix this file to satisfy the linter.
		var fix_question := (
			"Fix the lint errors in this file and only change what is necessary.\n"
			+ "File: %s\n"
			+ "Project root: res://\n"
			+ "Lint output:\n%s\n\n"
			+ "Use editor tools (apply_patch or write_file) to update the file.\n"
			+ "After making edits, assume lint will be rerun; keep iterating until it passes."
		) % [res_path, lint_output]

		var fix_resp := await _query_backend_for_tools(fix_question)
		var tool_calls := fix_resp.get("tool_calls", [])
		if tool_calls is Array and tool_calls.size() > 0 and _tool_executor:
			await _run_editor_actions_async(tool_calls, false, "lint_fix", fix_question)
		else:
			_post_system_message(
				("Auto-lint failed on %s (attempt %d/%d), but the backend did not return any tool calls to fix it.\n\nLint output:\n%s")
				% [res_path, attempt + 1, max_rounds, lint_output]
			)
			return

	# If we get here, we tried max_rounds and still failed.
	var final_lint := _run_headless_lint(project_dir, rel_path)
	var final_output: String = str(final_lint.get("output", "")).strip_edges()
	_post_system_message(
		("Gave up after %d auto-fix attempts; lint is still failing for %s.\n\nLast lint output:\n%s")
		% [max_rounds, res_path, final_output]
	)


func _run_headless_lint(project_dir_abs: String, rel_path_from_res: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var args: PackedStringArray = PackedStringArray([
		"--headless",
		"--editor",
		"--path", project_dir_abs,
		"--check-only", rel_path_from_res
	])

	var out: Array = []
	var exit_code := OS.execute(exe, args, out, true)
	var text := ""
	for line in out:
		text += str(line) + "\n"
	return {"ok": exit_code == 0, "exit_code": exit_code, "output": text}


func _query_backend_for_tools(question: String, lint_output: String = "") -> Dictionary:
	# Remember prompt so any tool-driven edits can be attributed.
	_last_tool_prompt = question
	_last_tool_trigger = "tool_action"
	var endpoint := rag_service_url + "/query"
	var active_script_path := ""
	var active_script_text := ""
	var active_scene_path := ""
	var project_root_abs := ProjectSettings.globalize_path("res://")
	if _editor_interface:
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
	if not chat.has("messages"):
		# Migrate old transcript to a single assistant message
		var transcript: String = chat.get("transcript", "")
		chat["messages"] = []
		if transcript.strip_edges().length() > 0:
			chat["messages"].append({"role": "assistant", "text": transcript})
		chat.erase("transcript")


func _ensure_default_chat() -> void:
	if chat_tab_bar == null:
		return
	if _chats.is_empty():
		var title := "Chat 1"
		_chats.append({"title": title, "messages": []})
		chat_tab_bar.clear_tabs()
		chat_tab_bar.add_tab(title)
		_current_chat = 0
		chat_tab_bar.current_tab = 0


func _on_new_chat_pressed() -> void:
	if chat_tab_bar == null:
		return
	var idx := _chats.size() + 1
	var title := "Chat %d" % idx
	_chats.append({"title": title, "messages": []})
	chat_tab_bar.add_tab(title)
	_current_chat = _chats.size() - 1
	chat_tab_bar.current_tab = _current_chat
	_streamed_markdown = ""
	_render_chat_log()


func _on_chat_tab_selected(tab_index: int) -> void:
	if tab_index < 0 or tab_index >= _chats.size():
		return
	_current_chat = tab_index
	_ensure_chat_has_messages()
	var messages: Array = _chats[tab_index].get("messages", [])
	_streamed_markdown = ""
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		_streamed_markdown = messages[messages.size() - 1].get("text", "")
	_render_chat_log()


func _on_main_tab_changed(tab_index: int) -> void:
	if tab_container and tab_index == 2:
		_refresh_settings_tab_from_config()
	if tab_container and tab_index == 1:
		_refresh_history()


func _on_history_refresh_pressed() -> void:
	_refresh_history()


func _refresh_history() -> void:
	var data := await _query_backend_json("%s/edit_events/list?limit=200" % rag_service_url, HTTPClient.METHOD_GET, "")
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
		history_detail_label.clear()

	for e in _history_events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id_val := int(e.get("id", -1))
		var summary := str(e.get("summary", ""))
		var trigger := str(e.get("trigger", ""))
		var changes = e.get("changes", [])
		var add_total := 0
		var rem_total := 0
		if changes is Array:
			for c in changes:
				if typeof(c) == TYPE_DICTIONARY:
					add_total += int(c.get("lines_added", 0))
					rem_total += int(c.get("lines_removed", 0))
		var label := "#%d  [+%d -%d]  %s  (%s)" % [id_val, add_total, rem_total, summary, trigger]
		history_list.add_item(label)


func _on_history_item_selected(index: int) -> void:
	if index < 0 or index >= _history_events.size():
		return
	var e = _history_events[index]
	if typeof(e) != TYPE_DICTIONARY:
		return
	_selected_history_edit_id = int(e.get("id", -1))
	if history_detail_label:
		history_detail_label.clear()
		var parts: Array[String] = []
		parts.append("[b]Edit #%d[/b]\n" % _selected_history_edit_id)
		parts.append("[b]Summary:[/b] %s\n" % str(e.get("summary", "")))
		parts.append("[b]Trigger:[/b] %s\n" % str(e.get("trigger", "")))
		var changes = e.get("changes", [])
		if changes is Array:
			for c in changes:
				if typeof(c) != TYPE_DICTIONARY:
					continue
				parts.append("\n[b]File:[/b] %s  ([+%d -%d], %s)\n" % [
					str(c.get("file_path", "")),
					int(c.get("lines_added", 0)),
					int(c.get("lines_removed", 0)),
					str(c.get("change_type", "modify")),
				])
				var diff := str(c.get("diff", ""))
				if not diff.is_empty():
					parts.append("[code]" + _escape_bbcode(diff) + "[/code]\n")
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
	status_label.text = "Settings saved."


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


func _on_settings_pressed() -> void:
	if tab_container:
		tab_container.current_tab = 1


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
	status_label.text = "Checking backend..."
	var err := http_request.request(url)
	if err != OK:
		status_label.text = "Failed to start health check."
		_pending_http_kind = &""
