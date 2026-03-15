@tool
extends Control
class_name GodotAIDock

const _LOG_PREFIX := "[AI Assistant] "
const _ContextPayloadScript: GDScript = preload("res://addons/godot_ai_assistant/core/context_payload.gd")

@onready var tab_container: TabContainer = $TabContainer
@onready var chat_tab_bar: TabBar = $TabContainer/Chat/VBox/ChatTabBarRow/ChatTabBar
@onready var context_usage_label: Label = $TabContainer/Chat/VBox/ChatTabBarRow/ContextUsageLabel
@onready var new_chat_button: Button = $TabContainer/Chat/VBox/ChatTabBarRow/NewChatButton
@onready var current_activity_label: Label = $TabContainer/Chat/VBox/ActivityBlock/CurrentActivityLabel
@onready var thought_history_button: Button = $TabContainer/Chat/VBox/ActivityBlock/ThoughtHistoryButton
@onready var thought_history_list: VBoxContainer = $TabContainer/Chat/VBox/ActivityBlock/ThoughtHistoryList
@onready var tool_calls_button: Button = $TabContainer/Chat/VBox/ActivityBlock/ToolCallsButton
@onready var tool_calls_list: VBoxContainer = $TabContainer/Chat/VBox/ActivityBlock/ToolCallsList
@onready var chat_scroll: ScrollContainer = $TabContainer/Chat/VBox/IOContainer/ChatScroll
@onready var chat_message_list: VBoxContainer = $TabContainer/Chat/VBox/IOContainer/ChatScroll/ChatMessageList
var output_text_edit: RichTextLabel = null  # Optional: used only when chat_message_list is missing (fallback)
@onready var prompt_text_edit: TextEdit = $TabContainer/Chat/VBox/IOContainer/PromptTextEdit
@onready var model_option: OptionButton = $TabContainer/Chat/VBox/BottomRow/ToolRow/ModelOption
@onready var ask_button: Button = $TabContainer/Chat/VBox/BottomRow/ToolRow/AskButton
@onready var copy_button: Button = $TabContainer/Chat/VBox/BottomRow/ToolRow/CopyButton
@onready var follow_agent_check: CheckButton = $TabContainer/Chat/VBox/BottomRow/ToolRow/FollowAgentCheck
@onready var context_viewer_button: Button = $TabContainer/Chat/VBox/BottomRow/ToolRow/ContextViewerButton
@onready var io_container: VSplitContainer = $TabContainer/Chat/VBox/IOContainer
@onready var pinned_context_row: HBoxContainer = $TabContainer/Chat/VBox/IOContainer/PinnedContextRow
@onready var add_current_script_button: Button = $TabContainer/Chat/VBox/IOContainer/AddContextRow/AddCurrentScriptButton
@onready var context_viewer_panel: VBoxContainer = $TabContainer/Chat/VBox/ContextViewerPanel
@onready var context_viewer_list: VBoxContainer = $TabContainer/Chat/VBox/ContextViewerPanel/ContextViewerScroll/ContextViewerList
@onready var context_viewer_empty_label: Label = $TabContainer/Chat/VBox/ContextViewerPanel/ContextViewerEmptyLabel
var status_label: Label = null  # Optional: StatusLabel removed from UI
@onready var http_request: HTTPRequest = $HTTPRequest
@onready var history_refresh_button: Button = $TabContainer/History/Margin/HistoryVBox/HistoryTopRow/HistoryRefreshButton
@onready var history_list: ItemList = $TabContainer/History/Margin/HistoryVBox/HistorySplit/HistoryList
@onready var history_detail_label: RichTextLabel = $TabContainer/History/Margin/HistoryVBox/HistorySplit/HistoryDetailVBox/HistoryDetailLabel
@onready var history_undo_button: Button = $TabContainer/History/Margin/HistoryVBox/HistorySplit/HistoryDetailVBox/HistoryUndoButton
@onready var history_usage_label: Label = $TabContainer/History/Margin/HistoryVBox/HistoryUsageVBox/HistoryUsageLabel
@onready var settings_text_size_spin: SpinBox = $TabContainer/Settings/Margin/Scroll/SettingsVBox/DisplaySection/TextSizeRow/SettingsTextSizeSpin
@onready var settings_word_wrap_check: CheckButton = $TabContainer/Settings/Margin/Scroll/SettingsVBox/DisplaySection/SettingsWordWrapCheck
@onready var settings_rag_url_edit: LineEdit = $TabContainer/Settings/Margin/Scroll/SettingsVBox/AISection/RagUrlRow/SettingsRagUrlEdit
@onready var settings_backend_option: OptionButton = $TabContainer/Settings/Margin/Scroll/SettingsVBox/AISection/BackendRow/SettingsBackendOption
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
var _backend_api: GodotAIBackendAPI = null
var _tool_runner: GodotAIToolRunner = null
var _chat_state: GodotAIChatState = null
var _chat_renderer: GodotAIChatRenderer = null
var _activity_state: GodotAIActivityState = null
var _changes_tab: GodotAIChangesTab = null
var _history_tab: GodotAIHistoryTab = null
var _settings_tab: GodotAISettingsTab = null
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
# Label at bottom of chat that shows "Thinking..." / "Tool call: X" + elapsed (updated in _process).
var _inline_activity_label: Label = null

# When user sends a new message while streaming, we increment this so the old stream's callbacks are ignored.
var _stream_generation: int = 0
var _stream_start_generation: int = -1
var _stream_message_index: int = -1
# Chat index that started the current stream; -1 if none. Used so Send/Stop reflects the selected chat.
var _streaming_chat_index: int = -1

## Typewriter reveal for assistant text (plain chars until caught up, then markdown).
var _tw_visible: int = 0
var _typewriter_timer: Timer = null
var _chat_scroll_tween: Tween = null
var _tw_active_chat_index: int = -1
const _TYPEWRITER_CHARS_PER_TICK := 5

# Last lint result (client or backend) so the next query can send it to RAG as context.
var _last_lint_path: String = ""
var _last_lint_output: String = ""
# Re-run lint after edits and send follow-up until clean or cap (so we fix all errors, not just the first).
const LINT_FOLLOW_UP_CAP := 5
var _lint_follow_up_count_this_turn: int = 0

func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e
	_tool_executor = GodotAIEditorToolExecutor.new(e) if e else null
	_settings = GodotAISettings.new()
	_settings.set_editor_interface(e)
	_edit_store = GodotAIEditStore.new()
	_edit_store.load_from_disk()
	_decorator = GodotAIEditorDecorator.new(e, _edit_store)
	_backend_api = GodotAIBackendAPI.new(self)
	_tool_runner = GodotAIToolRunner.new(self)
	_chat_state = GodotAIChatState.new(self)
	_chat_renderer = GodotAIChatRenderer.new(self)
	_activity_state = GodotAIActivityState.new(self)
	_changes_tab = GodotAIChangesTab.new(self)
	_history_tab = GodotAIHistoryTab.new(self)
	_settings_tab = GodotAISettingsTab.new(self)
	if _editor_interface:
		var base := _editor_interface.get_base_control()
		if base:
			_ask_icon_idle = base.get_theme_icon("Play", "EditorIcons")
			_ask_icon_busy = base.get_theme_icon("Reload", "EditorIcons")


# Public API for modules (avoids private-access errors from helper scripts)
func get_chats() -> Array:
	return _chats

func set_chats_arr(a: Array) -> void:
	_chats = a

func get_current_chat() -> int:
	return _current_chat

func set_current_chat_index(i: int) -> void:
	_current_chat = i

## Generate a stable unique id for a new chat (used for OpenViking session memory).
func generate_chat_id() -> String:
	return "c_%d_%d" % [Time.get_ticks_msec(), randi() % 1000000]

## Return the current chat's stable id, or empty string if none (for backend context.extra.chat_id).
func get_current_chat_id() -> String:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return ""
	var c = _chats[_current_chat]
	if typeof(c) != TYPE_DICTIONARY:
		return ""
	var id_val = c.get("id", "")
	return str(id_val) if id_val else ""


func get_settings() -> GodotAISettings:
	return _settings

func get_edit_store() -> GodotAIEditStore:
	return _edit_store

func get_backend_api() -> GodotAIBackendAPI:
	return _backend_api

func get_tool_executor() -> GodotAIEditorToolExecutor:
	return _tool_executor

func get_editor_interface_ref() -> EditorInterface:
	return _editor_interface

## Ask the editor to rescan the resource filesystem so new/updated files show in the FileSystem dock.
func request_editor_filesystem_refresh() -> void:
	if not _editor_interface:
		return
	var efs = _editor_interface.get_resource_filesystem()
	if efs and efs.has_method("scan"):
		call_deferred("_do_editor_filesystem_scan", efs)

func _do_editor_filesystem_scan(efs: EditorFileSystem) -> void:
	if efs and is_instance_valid(efs):
		efs.scan()

func get_last_tool_prompt() -> String:
	return _last_tool_prompt

func set_last_tool_prompt(s: String) -> void:
	_last_tool_prompt = s

func get_last_tool_trigger() -> String:
	return _last_tool_trigger

func set_last_tool_trigger(s: String) -> void:
	_last_tool_trigger = s

func get_streamed_markdown() -> String:
	return _streamed_markdown

func set_streamed_markdown(s: String) -> void:
	_streamed_markdown = s

func is_streaming_in_progress() -> bool:
	return _streaming_in_progress

func get_markdown_renderer() -> GodotAIMarkdownRenderer:
	return _markdown_renderer

func get_current_activity() -> Dictionary:
	return _current_activity

func set_current_activity_dict(d: Dictionary) -> void:
	_current_activity = d

func get_activity_history() -> Array:
	return _activity_history

func set_activity_history_arr(a: Array) -> void:
	_activity_history = a

func get_activity_glow_tween() -> Tween:
	return _activity_glow_tween

func set_activity_glow_tween_ref(t: Tween) -> void:
	_activity_glow_tween = t


func set_inline_activity_label(l: Label) -> void:
	_inline_activity_label = l


func get_inline_activity_label() -> Label:
	return _inline_activity_label

func get_history_events() -> Array:
	return _history_events

func set_history_events_arr(a: Array) -> void:
	_history_events = a

func get_selected_history_edit_id() -> int:
	return _selected_history_edit_id

func set_selected_history_edit_id(i: int) -> void:
	_selected_history_edit_id = i

func get_selected_pending_id() -> String:
	return _selected_pending_id

func set_selected_pending_id_val(s: String) -> void:
	_selected_pending_id = s

func get_selected_timeline_id() -> String:
	return _selected_timeline_id

func set_selected_timeline_id_val(s: String) -> void:
	_selected_timeline_id = s

func set_status(t: String) -> void:
	_set_status(t)

func push_activity(line: String) -> void:
	_push_activity(line)


func clear_activity() -> void:
	_clear_activity()
	_set_status("")

func request_backend_lint(res_path: String) -> Dictionary:
	return await _request_backend_lint(res_path)

func query_backend_for_tools(question: String, lint_output: String = "", override_file_path: String = "", override_file_text: String = "") -> Dictionary:
	return await _query_backend_for_tools(question, lint_output, override_file_path, override_file_text)

func run_editor_actions_async(tool_calls: Array, proposal_mode: bool, trigger: String = "", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _run_editor_actions_async(tool_calls, proposal_mode, trigger, prompt, lint_errors_before, lint_errors_after)

func post_system_message(text: String) -> void:
	_post_system_message(text)

func ensure_chat_has_messages() -> void:
	_ensure_chat_has_messages()

func render_chat_log() -> void:
	_render_chat_log()

func apply_editor_decorations() -> void:
	_apply_editor_decorations()

func escape_bbcode(t: String) -> String:
	return _escape_bbcode(t)

func query_backend_json(endpoint: String, method: int, body: String) -> Variant:
	return await _query_backend_json(endpoint, method, body)

func lint_and_autofix_return_ok(res_path: String, max_rounds: int) -> bool:
	return await _lint_and_autofix_return_ok(res_path, max_rounds)

func should_lint_path(path: String) -> bool:
	return _should_lint_path(path)

func log_edit_event_to_backend(edit_records: Array, trigger: String = "tool_action", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _log_edit_event_to_backend(edit_records, trigger, prompt, lint_errors_before, lint_errors_after)


func _set_status(t: String) -> void:
	if status_label:
		status_label.text = t


func _ready() -> void:
	print("AI Assistant: _ready called on dock")
	if _typewriter_timer == null:
		_typewriter_timer = Timer.new()
		_typewriter_timer.wait_time = 0.028
		_typewriter_timer.timeout.connect(_on_typewriter_timer_timeout)
		add_child(_typewriter_timer)
	output_text_edit = get_node_or_null("TabContainer/Chat/VBox/IOContainer/OutputText") as RichTextLabel
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
		prompt_text_edit.text_changed.connect(_update_ask_button_state)

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
		chat_tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
		chat_tab_bar.tab_selected.connect(_on_chat_tab_selected)
		if chat_tab_bar.has_signal("active_tab_rearranged"):
			chat_tab_bar.active_tab_rearranged.connect(_on_chat_tab_rearranged)
		if chat_tab_bar.has_signal("tab_close_pressed"):
			chat_tab_bar.tab_close_pressed.connect(_on_chat_tab_close_pressed)
	if model_option:
		model_option.item_selected.connect(_on_model_selected)
	if follow_agent_check:
		follow_agent_check.toggled.connect(_on_follow_agent_toggled)
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
	if settings_backend_option:
		settings_backend_option.item_selected.connect(_on_settings_backend_selected)
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
	# Activity (Thinking... / Tool call: X) is shown inline at bottom of chat, not at top.
	if current_activity_label:
		current_activity_label.visible = false
	if context_viewer_button:
		context_viewer_button.pressed.connect(_on_context_viewer_button_pressed)
	if add_current_script_button:
		add_current_script_button.pressed.connect(_on_add_current_script_pressed)

	_apply_settings_from_config()
	_update_context_usage_label()
	if _chat_state:
		_chat_state.ensure_default_chat()
	_refresh_pinned_context_row()
	if _settings_tab:
		_settings_tab.refresh_settings_tab_from_config()
	_start_health_check()
	if _changes_tab:
		_changes_tab.render_changes_tab()
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
	# Use one-shot + reschedule so a single "method not found" doesn't spam if script reloads.
	if _decoration_timer != null:
		return
	_decoration_timer = Timer.new()
	_decoration_timer.wait_time = 1.0
	_decoration_timer.one_shot = true
	add_child(_decoration_timer)
	_decoration_timer.timeout.connect(_on_decoration_timer_timeout)
	_decoration_timer.start()


func _on_decoration_timer_timeout() -> void:
	# Only do work if we have anything to show.
	if _edit_store == null:
		_reschedule_decoration_timer()
		return
	if _edit_store.file_status.is_empty() and _edit_store.node_status.is_empty():
		_reschedule_decoration_timer()
		return
	_apply_editor_decorations()
	_reschedule_decoration_timer()


func _reschedule_decoration_timer() -> void:
	if _decoration_timer != null and is_instance_valid(_decoration_timer):
		_decoration_timer.start(1.0)


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
	# Stop: cancel the stream for the current chat if this chat is the one streaming.
	if _streaming_in_progress and _streaming_chat_index == _current_chat:
		_stream_generation += 1
		_streaming_in_progress = false
		_streaming_chat_index = -1
		_update_ask_button_state()
		clear_activity()
		_set_status("Stopped.")
		return
	var question: String = prompt_text_edit.text.strip_edges()
	if question.is_empty():
		_set_status("Please enter a question.")
		return

	# If a query is already running (another chat), supersede it so we run this one instead.
	if _streaming_in_progress:
		_stream_generation += 1

	# Remember the originating prompt so any subsequent tool-driven edits can be logged server-side.
	_last_tool_prompt = question
	_last_tool_trigger = "tool_action"
	_lint_follow_up_count_this_turn = 0

	# Add user and placeholder assistant messages first, then render so user sees their message instantly.
	_ensure_chat_has_messages()
	var messages: Array = _chats[_current_chat]["messages"]
	# Persist activity history to the last assistant message so inline "Thought history" has data.
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		messages[messages.size() - 1]["activity_history"] = _activity_history.duplicate()
	_chats[_current_chat]["messages"].append({"role": "user", "text": question})
	_chats[_current_chat]["messages"].append({"role": "assistant", "text": ""})
	_streamed_markdown = ""
	_tw_visible = 0
	_tw_active_chat_index = _current_chat
	_save_current_chat_activity()
	_clear_activity()
	if thought_history_list:
		thought_history_list.visible = false
	_update_activity_ui()
	_push_activity("Preparing…")
	_render_chat_log()
	scroll_output_to_bottom()

	# Clear input immediately so user sees their message and empty prompt in this frame.
	if prompt_text_edit:
		prompt_text_edit.text = ""

	# Defer building context and sending so this frame can paint the user message first.
	var use_tools: bool = true
	call_deferred("_deferred_send_question", question, use_tools)


func get_current_chat_exclude_context_keys() -> Array:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return []
	return (_chats[_current_chat].get("exclude_context_keys", []) as Array).duplicate()


## Drag-to-context: add items from editor drag data (FileSystem files, Scene tree nodes, script tabs).
func add_pinned_context_from_drag_data(data: Variant) -> void:
	if data == null or not data is Dictionary:
		return
	_ensure_chat_has_messages()
	if _current_chat < 0 or _current_chat >= _chats.size():
		return
	var chat: Dictionary = _chats[_current_chat]
	if not chat.has("pinned_context"):
		chat["pinned_context"] = []
	var pinned: Array = chat["pinned_context"]
	var d: Dictionary = data

	# FileSystem dock: data["files"] = PackedStringArray or Array of paths
	if d.has("files"):
		var files: Variant = d["files"]
		var paths: Array = []
		if files is PackedStringArray:
			for i in (files as PackedStringArray).size():
				paths.append((files as PackedStringArray)[i])
		elif files is Array:
			paths = (files as Array).duplicate()
		for path in paths:
			var p: String = str(path).strip_edges()
			if p.is_empty():
				continue
			if not p.begins_with("res://"):
				p = "res://" + p
			var entry: Dictionary = {"type": "file", "path": p}
			if _pinned_context_contains(pinned, entry):
				continue
			pinned.append(entry)

	# Scene tree: data["nodes"] (array of NodePath or dicts), optional data["scene"] / "from_scene"
	elif d.has("nodes"):
		var nodes_raw: Variant = d["nodes"]
		var scene_path: String = str(d.get("scene", d.get("from_scene", ""))).strip_edges()
		if scene_path.is_empty() and _editor_interface:
			var root = _editor_interface.get_edited_scene_root()
			if root:
				scene_path = root.scene_file_path
		var root_node = _editor_interface.get_edited_scene_root() if _editor_interface else null
		var root_name: String = root_node.name if root_node else ""
		var node_list: Array = nodes_raw if nodes_raw is Array else []
		for n in node_list:
			var node_path_str: String = ""
			var node_name_str: String = ""
			if n is NodePath:
				node_path_str = str(n)
				node_name_str = (n as NodePath).get_name((n as NodePath).get_name_count() - 1)
			elif n is Dictionary:
				node_path_str = str((n as Dictionary).get("path", (n as Dictionary).get("node_path", "")))
				node_name_str = str((n as Dictionary).get("name", (n as Dictionary).get("node_name", "")))
			else:
				node_path_str = str(n)
			if node_path_str.is_empty():
				continue
			if node_name_str.is_empty():
				node_name_str = node_path_str.get_file()
			# Treat scene root as a special entry so we show "Scene root (scene.tscn)" not just the node name
			var is_scene_root: bool = (
				node_path_str == "." or node_path_str == "/"
				or (root_name and (node_name_str == root_name or node_path_str == root_name))
			)
			var entry: Dictionary
			if is_scene_root and not scene_path.is_empty():
				entry = {"type": "scene_root", "scene_path": scene_path, "node_name": root_name if root_name else "Root"}
			else:
				entry = {"type": "node", "node_path": node_path_str, "node_name": node_name_str, "scene_path": scene_path}
			if _pinned_context_contains(pinned, entry):
				continue
			pinned.append(entry)

	# Single resource/script (e.g. script tab drag)
	elif d.has("resource_path"):
		var p: String = str(d.get("resource_path", "")).strip_edges()
		if not p.is_empty():
			if not p.begins_with("res://"):
				p = "res://" + p
			var entry: Dictionary = {"type": "file", "path": p}
			if not _pinned_context_contains(pinned, entry):
				pinned.append(entry)
	elif d.has("script") and d["script"] != null:
		var scr: Script = d["script"] as Script
		if scr and scr.resource_path:
			var p: String = scr.resource_path
			var entry: Dictionary = {"type": "file", "path": p}
			if not _pinned_context_contains(pinned, entry):
				pinned.append(entry)

	_refresh_pinned_context_row()
	_set_status("Added to context for this chat.")


func _pinned_context_contains(pinned: Array, entry: Dictionary) -> bool:
	var path_a: String = str(entry.get("path", "")).strip_edges()
	var node_path_a: String = str(entry.get("node_path", "")).strip_edges()
	var scene_path_a: String = str(entry.get("scene_path", "")).strip_edges()
	for e in pinned:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if d.get("type") == "file" and path_a and str(d.get("path", "")).strip_edges() == path_a:
			return true
		if d.get("type") == "node" and node_path_a and str(d.get("node_path", "")).strip_edges() == node_path_a:
			return true
		if d.get("type") == "scene_root" and scene_path_a and str(d.get("scene_path", "")).strip_edges() == scene_path_a:
			return true
	return false


func get_current_chat_pinned_context() -> Array:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return []
	return (_chats[_current_chat].get("pinned_context", []) as Array).duplicate()


func remove_pinned_context(chat_index: int, entry_index: int) -> void:
	if chat_index < 0 or chat_index >= _chats.size():
		return
	var chat: Dictionary = _chats[chat_index]
	if not chat.has("pinned_context"):
		return
	var pinned: Array = chat["pinned_context"]
	if entry_index < 0 or entry_index >= pinned.size():
		return
	pinned.remove_at(entry_index)
	_refresh_pinned_context_row()


func _build_pinned_context_extra() -> Dictionary:
	var out: Dictionary = {}
	var pinned: Array = get_current_chat_pinned_context()
	if pinned.is_empty():
		return out
	var files_arr: Array = []
	var nodes_arr: Array = []
	for e in pinned:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if d.get("type") == "file":
			var path: String = str(d.get("path", "")).strip_edges()
			if path.is_empty():
				continue
			var content: String = GodotAIContextPayload.read_file_res(path) if path else ""
			files_arr.append({"path": path, "content": content})
		elif d.get("type") == "scene_root":
			var scene_path: String = str(d.get("scene_path", "")).strip_edges()
			var node_name: String = str(d.get("node_name", "")).strip_edges()
			var scene_file: String = scene_path.get_file() if scene_path else "scene"
			var desc: String = "Scene root (%s)" % scene_file
			if _editor_interface and scene_path:
				var root = _editor_interface.get_edited_scene_root()
				if root and root.scene_file_path == scene_path:
					desc = "Scene root: %s (%s) — %s" % [root.name, root.get_class(), scene_file]
			nodes_arr.append({"scene_path": scene_path, "node_path": ".", "node_name": node_name, "description": desc, "is_scene_root": true})
		elif d.get("type") == "node":
			var node_path_str: String = str(d.get("node_path", "")).strip_edges()
			var node_name: String = str(d.get("node_name", "")).strip_edges()
			var scene_path: String = str(d.get("scene_path", "")).strip_edges()
			var desc: String = "Node: %s (path: %s)" % [node_name, node_path_str]
			if _editor_interface and scene_path:
				var root = _editor_interface.get_edited_scene_root()
				if root and root.scene_file_path == scene_path:
					var n: Node = root.get_node_or_null(node_path_str)
					if n:
						desc = "Node: %s (%s) path=%s" % [n.name, n.get_class(), node_path_str]
			nodes_arr.append({"scene_path": scene_path, "node_path": node_path_str, "node_name": node_name, "description": desc})
	if files_arr.size() > 0:
		out["pinned_files"] = files_arr
	if nodes_arr.size() > 0:
		out["pinned_nodes"] = nodes_arr
	# So the model knows these were explicitly dragged by the user
	if files_arr.size() > 0 or nodes_arr.size() > 0:
		out["pinned_context_note"] = "The user just dragged these items into context for this chat. Prioritize them when answering."
	return out


func _refresh_pinned_context_row() -> void:
	if not pinned_context_row:
		return
	for c in pinned_context_row.get_children():
		c.queue_free()
	var pinned: Array = get_current_chat_pinned_context()
	pinned_context_row.visible = not pinned.is_empty()
	if pinned.is_empty():
		return
	var chat_idx: int = _current_chat
	for i in range(pinned.size()):
		var e: Variant = pinned[i]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var label_text: String = ""
		if d.get("type") == "file":
			label_text = (str(d.get("path", "")).strip_edges() as String).get_file()
		elif d.get("type") == "scene_root":
			var sp: String = str(d.get("scene_path", "")).strip_edges()
			label_text = "Scene root (%s)" % (sp.get_file() if sp else "?")
		else:
			label_text = "Node: " + str(d.get("node_name", "?")).strip_edges()
		var chip_tooltip: String = "Dragged into context. Click × to remove."
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 4)
		var lbl := Label.new()
		lbl.text = label_text
		lbl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		lbl.custom_minimum_size.x = 1
		chip.add_child(lbl)
		var rm := Button.new()
		rm.flat = true
		rm.text = "×"
		rm.tooltip_text = "Remove from context"
		lbl.tooltip_text = chip_tooltip
		var idx := i
		rm.pressed.connect(remove_pinned_context.bind(chat_idx, idx))
		chip.add_child(rm)
		pinned_context_row.add_child(chip)


func get_current_chat_conversation_messages() -> Array:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return []
	return _chats[_current_chat].get("messages", [])


func _deferred_send_question(
	question: String,
	use_tools: bool,
	override_file_path: String = "",
	override_file_text: String = "",
	lint_output_override: String = ""
) -> void:
	_push_activity("Building context…")
	var conversation_messages: Array = []
	if _current_chat >= 0 and _current_chat < _chats.size():
		conversation_messages = _chats[_current_chat].get("messages", [])
	var context: Dictionary = GodotAIContextPayload.build(
		_editor_interface,
		override_file_path,
		override_file_text,
		lint_output_override if not lint_output_override.is_empty() else "",
		conversation_messages
	)
	var current_script: String = str(context.get("current_script", ""))
	if not context.has("extra"):
		context["extra"] = {}
	if not lint_output_override.is_empty():
		context["extra"]["lint_output"] = lint_output_override
	elif _last_lint_path and str(current_script) == str(_last_lint_path) and not _last_lint_output.is_empty():
		context["extra"]["lint_output"] = _last_lint_output
	var exclude_keys: Array = get_current_chat_exclude_context_keys()
	if exclude_keys.size() > 0:
		context["extra"]["exclude_block_keys"] = exclude_keys
	var chat_id_str: String = get_current_chat_id()
	if not chat_id_str.is_empty():
		context["extra"]["chat_id"] = chat_id_str
	# Include user-dragged context (files/nodes from FileSystem, Scene tree, Script list).
	var pinned_extra: Dictionary = _build_pinned_context_extra()
	for k in pinned_extra:
		context["extra"][k] = pinned_extra[k]
	var payload: Dictionary = {
		"question": question,
		"context": context,
		"top_k": 8
	}
	if _settings:
		if _settings.openai_api_key.length() > 0:
			payload["api_key"] = _settings.openai_api_key
		var model := _settings.get_effective_model()
		if model.length() > 0:
			payload["model"] = model
		if _settings.openai_base_url.length() > 0:
			payload["base_url"] = _settings.openai_base_url
	var json_body: String = JSON.stringify(payload)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var profile_id: String = _settings.backend_profile_id if _settings else GodotAIBackendProfile.PROFILE_RAG
	var profile := GodotAIBackendProfile.get_profile(profile_id)
	var stream_endpoint: String = profile.get_stream_with_tools_url(rag_service_url) if use_tools else profile.get_stream_url(rag_service_url)
	_stream_start_generation = _stream_generation
	_stream_message_index = _chats[_current_chat]["messages"].size() - 1 if _current_chat >= 0 and _current_chat < _chats.size() else -1
	_streaming_in_progress = true
	_streaming_chat_index = _current_chat
	_update_ask_button_state()
	_push_activity("Calling AI…")
	_async_stream_request(stream_endpoint, headers, json_body)


func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	print("AI Assistant: HTTP request completed. result=", result, " code=", response_code)

	if result != HTTPRequest.RESULT_SUCCESS:
		var msg := "Request failed: %d" % result
		_set_status(msg)
		_append_error_to_chat(msg)
		_pending_http_kind = &""
		return

	if response_code < 200 or response_code >= 300:
		var msg := "HTTP error: %d" % response_code
		_set_status(msg)
		_append_error_to_chat(msg)
		_pending_http_kind = &""
		return

	var body_text: String = body.get_string_from_utf8()
	print("AI Assistant: response body: ", body_text)

	var json := JSON.new()
	var parse_result: int = json.parse(body_text)
	if parse_result != OK:
		var msg := "Failed to parse JSON response from backend."
		_set_status(msg)
		_append_error_to_chat(msg)
		_pending_http_kind = &""
		return

	var data := json.data
	if typeof(data) != TYPE_DICTIONARY:
		var msg := "Unexpected response format from backend."
		_set_status(msg)
		_append_error_to_chat(msg)
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
			if context_viewer_panel and context_viewer_panel.visible:
				_refresh_context_viewer_panel()
		var tool_calls_raw = data.get("tool_calls", [])
		_ensure_chat_has_messages()
		var messages: Array = _chats[_current_chat]["messages"]
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["text"] = answer
		else:
			messages.append({"role": "assistant", "text": answer})
		_streamed_markdown = ""
		_tw_visible = 0
		_tw_active_chat_index = _current_chat
		_render_chat_log()
		if _typewriter_timer != null:
			_typewriter_timer.start()
		_set_status("Response received.")
		if tool_calls_raw is Array and tool_calls_raw.size() > 0:
			var summaries: Array = _format_tool_calls_summaries(tool_calls_raw)
			if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
				messages[messages.size() - 1]["tool_calls_summary"] = summaries
			_update_tool_calls_ui()
			if _tool_executor:
				_run_editor_actions_then_lint_follow_up.call_deferred(tool_calls_raw, false, "tool_action", _last_tool_prompt, "", "")
		else:
			clear_activity()
		return

	_pending_http_kind = &""


func _on_copy_button_pressed() -> void:
	var text_to_copy: String = ""
	if chat_message_list != null and _current_chat >= 0 and _current_chat < _chats.size():
		var lines: PackedStringArray = []
		for msg in _chats[_current_chat].get("messages", []):
			if msg.get("hidden", false):
				continue
			var role: String = msg.get("role", "assistant")
			var text: String = msg.get("text", "")
			lines.append(role.capitalize() + ":\n" + text)
		text_to_copy = "\n\n".join(lines)
	elif output_text_edit:
		text_to_copy = output_text_edit.get_parsed_text()
	if text_to_copy.is_empty():
		_set_status("Nothing to copy.")
		return
	DisplayServer.clipboard_set(text_to_copy)
	_set_status("Copied answer to clipboard.")


func _is_stream_cancelled() -> bool:
	return _stream_generation != _stream_start_generation


func _async_stream_request(endpoint: String, _headers: PackedStringArray, body: String) -> void:
	print("AI Assistant: streaming request to ", endpoint)
	var cancel_check := Callable(self, "_is_stream_cancelled")
	await GodotAIBackendClient.stream_post(
		self,
		endpoint,
		body,
		_on_stream_chunk,
		_on_stream_done,
		cancel_check
	)


func _on_stream_chunk(delta: String) -> void:
	if _stream_start_generation != _stream_generation:
		return
	if _streaming_chat_index < 0 or _streaming_chat_index >= _chats.size():
		return
	var is_first_chunk: bool = _streamed_markdown.is_empty()
	if is_first_chunk:
		_push_activity("Streaming response…")
	_streamed_markdown += delta
	_ensure_chat_has_messages()
	var messages: Array = _chats[_streaming_chat_index]["messages"]
	if _stream_message_index >= 0 and _stream_message_index < messages.size() and messages[_stream_message_index].get("role", "") == "assistant":
		const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
		var marker_pos := _streamed_markdown.find(TOOL_CALLS_MARKER)
		if marker_pos >= 0:
			messages[_stream_message_index]["text"] = _streamed_markdown.substr(0, marker_pos)
		else:
			messages[_stream_message_index]["text"] = _streamed_markdown
	if is_first_chunk:
		_tw_visible = 0
		if _streaming_chat_index == _current_chat:
			_render_chat_log()
	if _typewriter_timer != null:
		_typewriter_timer.start()


func _on_stream_done(full_text: String, error_message: String = "") -> void:
	# Ignore completion from a superseded or cancelled stream (do not clear _streaming_chat_index here; another stream may be running).
	if _stream_start_generation != _stream_generation:
		return
	if not error_message.is_empty():
		_set_status(error_message)
		_append_error_to_chat(error_message)
		_streaming_in_progress = false
		_update_ask_button_state()
		clear_activity()
		return
	if full_text.is_empty():
		_set_status("Request ended with no response. (Cancelled or connection lost.)")
		_streaming_in_progress = false
		_update_ask_button_state()
		_clear_activity()
		return
	_streamed_markdown = full_text
	const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
	const USAGE_MARKER := "\n__USAGE__\n"
	var sci: int = _streaming_chat_index if _streaming_chat_index >= 0 else _current_chat
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
		if sci >= 0 and sci < _chats.size():
			var messages: Array = _chats[sci]["messages"]
			if _stream_message_index >= 0 and _stream_message_index < messages.size() and messages[_stream_message_index].get("role", "") == "assistant":
				messages[_stream_message_index]["text"] = display_text
			if not tool_calls_json.is_empty():
				var json := JSON.new()
				if json.parse(tool_calls_json) == OK and json.data is Array:
					var tool_arr: Array = json.data
					var summaries: Array = _format_tool_calls_summaries(tool_arr)
					if _stream_message_index >= 0 and _stream_message_index < messages.size() and messages[_stream_message_index].get("role", "") == "assistant":
						messages[_stream_message_index]["tool_calls_summary"] = summaries
					_update_tool_calls_ui()
					_run_editor_actions_then_lint_follow_up.call_deferred(tool_arr, false, "tool_action", _last_tool_prompt, "", "")
			if sci == _current_chat:
				_render_chat_log()
		if not usage_json.is_empty():
			var uj := JSON.new()
			if uj.parse(usage_json) == OK and uj.data is Dictionary and sci >= 0 and sci < _chats.size():
				_chats[sci]["context_usage"] = uj.data
				_update_context_usage_label()
				if context_viewer_panel and context_viewer_panel.visible:
					_refresh_context_viewer_panel()

	_streaming_in_progress = false
	_streaming_chat_index = -1
	_update_ask_button_state()
	clear_activity()
	if _typewriter_timer != null:
		_typewriter_timer.start()


func _update_ask_button_state() -> void:
	if not ask_button:
		return
	var prompt_empty: bool = prompt_text_edit == null or prompt_text_edit.text.strip_edges().is_empty()
	if _streaming_in_progress and _streaming_chat_index == _current_chat:
		# This chat is streaming: show Stop, enabled so user can cancel.
		ask_button.text = "Stop"
		ask_button.icon = null
		ask_button.disabled = false
	elif _streaming_in_progress:
		# Another chat is streaming: show Send, enabled so user can send in this chat (will supersede).
		ask_button.text = ""
		ask_button.icon = _ask_icon_idle if _ask_icon_idle else null
		ask_button.disabled = false
	else:
		# Not streaming: show Send, disabled only if prompt is empty.
		ask_button.text = ""
		ask_button.icon = _ask_icon_idle if _ask_icon_idle else null
		ask_button.disabled = prompt_empty


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


func _on_context_viewer_button_pressed() -> void:
	if not io_container or not context_viewer_panel:
		return
	var show_panel: bool = not context_viewer_panel.visible
	context_viewer_panel.visible = show_panel
	io_container.visible = not show_panel
	if show_panel:
		_refresh_context_viewer_panel()


func _on_add_current_script_pressed() -> void:
	## Add the script currently open in the Script Editor to this chat's pinned context (same as dragging the tab).
	if not _editor_interface:
		_set_status("No editor.")
		return
	var script_editor = _editor_interface.get_script_editor()
	if not script_editor or not script_editor.has_method("get_current_script"):
		_set_status("Script editor not available.")
		return
	var current: Script = script_editor.get_current_script()
	if not current or not current.resource_path:
		_set_status("No script open in the Script Editor.")
		return
	add_pinned_context_from_drag_data({"resource_path": current.resource_path})


func _refresh_context_viewer_panel() -> void:
	if not context_viewer_list or not context_viewer_empty_label:
		return
	# Clear existing block UIs
	for child in context_viewer_list.get_children():
		child.queue_free()
	var usage: Dictionary = {}
	if _current_chat >= 0 and _current_chat < _chats.size():
		usage = _chats[_current_chat].get("context_usage", {})
	var view_arr: Array = usage.get("context_view", [])
	if view_arr.is_empty():
		context_viewer_empty_label.visible = true
		context_viewer_list.get_parent().visible = false
		return
	context_viewer_empty_label.visible = false
	context_viewer_list.get_parent().visible = true
	var exclude_keys: Array = []
	if _current_chat >= 0 and _current_chat < _chats.size():
		exclude_keys = _chats[_current_chat].get("exclude_context_keys", [])
	for blk in view_arr:
		if typeof(blk) != TYPE_DICTIONARY:
			continue
		var key: String = str(blk.get("key", ""))
		var title: String = str(blk.get("title", "Context block"))
		var est_tok: int = int(blk.get("estimated_tokens", 0))
		var included: bool = blk.get("included", true)
		var mode: String = str(blk.get("mode", "as_is"))
		var preview: String = str(blk.get("content_preview", ""))
		var user_excluded: bool = key in exclude_keys
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 4)
		var header_row := HBoxContainer.new()
		var header := Label.new()
		var badge: String = "Dropped" if not included else ("Excluded by you" if user_excluded else "Included")
		header.text = "%s  •  %d tokens  •  %s  •  %s" % [title, est_tok, badge, mode]
		if not included:
			header.add_theme_color_override("font_color", Color(0.6, 0.4, 0.4))
		elif user_excluded:
			header.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		else:
			header.add_theme_color_override("font_color", Color(0.4, 0.6, 0.4))
		header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header_row.add_child(header)
		var exclude_btn := Button.new()
		exclude_btn.text = "Don't include next time" if not user_excluded else "Include again"
		exclude_btn.pressed.connect(_toggle_exclude_context_block.bind(key))
		header_row.add_child(exclude_btn)
		box.add_child(header_row)
		var body := TextEdit.new()
		body.editable = false
		body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		body.text = preview
		body.custom_minimum_size.y = 120
		body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		box.add_child(body)
		context_viewer_list.add_child(box)

	# Decision log at the bottom (why blocks were included/dropped, path hints, etc.)
	var log_arr: Array = usage.get("context_decision_log", [])
	if not log_arr.is_empty():
		var sep := HSeparator.new()
		context_viewer_list.add_child(sep)
		var log_title := Label.new()
		log_title.text = "Context decisions"
		log_title.add_theme_font_size_override("font_size", 14)
		context_viewer_list.add_child(log_title)
		var log_text := "\n".join(log_arr)
		var log_body := TextEdit.new()
		log_body.editable = false
		log_body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		log_body.text = log_text
		log_body.custom_minimum_size.y = 80
		log_body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		context_viewer_list.add_child(log_body)


func _toggle_exclude_context_block(block_key: String) -> void:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return
	var chat: Dictionary = _chats[_current_chat]
	if not chat.has("exclude_context_keys"):
		chat["exclude_context_keys"] = []
	var arr: Array = chat["exclude_context_keys"]
	var idx := arr.find(block_key)
	if idx >= 0:
		arr.remove_at(idx)
	else:
		arr.append(block_key)
	_refresh_context_viewer_panel()


func _escape_bbcode(t: String) -> String:
	return GodotAIChatRenderer.escape_bbcode(t)


func scroll_output_to_bottom() -> void:
	_chat_renderer.scroll_output_to_bottom()


func _deferred_smooth_scroll_chat_to_bottom() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if chat_scroll == null:
		return
	var vbar: VScrollBar = chat_scroll.get_v_scroll_bar()
	if vbar == null:
		return
	var target: float = vbar.max_value
	if target <= 0.0:
		return
	if _chat_scroll_tween != null:
		_chat_scroll_tween.kill()
		_chat_scroll_tween = null
	if abs(vbar.value - target) < 3.0:
		vbar.value = target
		return
	_chat_scroll_tween = create_tween()
	_chat_scroll_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_chat_scroll_tween.tween_property(vbar, "value", target, 0.2)


func should_typewriter_assistant_at_index(idx: int) -> bool:
	if _current_chat < 0 or _current_chat >= _chats.size():
		return false
	var messages: Array = _chats[_current_chat].get("messages", [])
	if idx < 0 or idx >= messages.size():
		return false
	if str(messages[idx].get("role", "")) != "assistant":
		return false
	if idx != messages.size() - 1:
		return false
	var full: String = str(messages[idx].get("text", ""))
	if full.is_empty():
		return false
	var streaming_here := _streaming_in_progress and _streaming_chat_index == _current_chat
	if streaming_here:
		return true
	return _tw_active_chat_index == _current_chat and _tw_visible < full.length()


func get_typewriter_plain_slice(full_text: String) -> String:
	return full_text.substr(0, mini(_tw_visible, full_text.length()))


func _on_typewriter_timer_timeout() -> void:
	if _typewriter_timer == null:
		return
	var chat_i := _streaming_chat_index if (_streaming_in_progress and _streaming_chat_index >= 0) else _tw_active_chat_index
	if chat_i < 0 or chat_i >= _chats.size():
		_typewriter_timer.stop()
		return
	var messages: Array = _chats[chat_i].get("messages", [])
	if messages.is_empty():
		_typewriter_timer.stop()
		return
	var last_idx := messages.size() - 1
	var last: Variant = messages[last_idx]
	if typeof(last) != TYPE_DICTIONARY or str(last.get("role", "")) != "assistant":
		_typewriter_timer.stop()
		return
	var full: String = str(last.get("text", ""))
	var streaming_here := _streaming_in_progress and _streaming_chat_index >= 0
	if full.is_empty():
		return
	_tw_visible = mini(_tw_visible + _TYPEWRITER_CHARS_PER_TICK, full.length())
	if chat_i == _current_chat:
		_render_chat_log()
		scroll_output_to_bottom()
	if not streaming_here and _tw_visible >= full.length():
		_typewriter_timer.stop()
		_tw_active_chat_index = -1
		if chat_i == _current_chat:
			_render_chat_log()
			scroll_output_to_bottom()


func _save_current_chat_activity() -> void:
	_activity_state.save_current_chat_activity()


func _push_activity(line: String) -> void:
	_activity_state.push_activity(line)


func _clear_activity() -> void:
	_activity_state.clear_activity()


func _format_elapsed(sec: float) -> String:
	return GodotAIActivityState.format_elapsed(sec)


func _update_activity_ui() -> void:
	_activity_state.update_activity_ui()


func _start_activity_glow() -> void:
	_activity_state.start_activity_glow()


func _stop_activity_glow() -> void:
	_activity_state.stop_activity_glow()


func _on_thought_history_toggled() -> void:
	if thought_history_list:
		thought_history_list.visible = not thought_history_list.visible
	if thought_history_button and _activity_history.size() > 0:
		var suffix := " ▼" if thought_history_list.visible else " ▶"
		thought_history_button.text = "Thought history (%d)" % _activity_history.size() + suffix


func _on_tool_calls_toggled() -> void:
	if tool_calls_list and tool_calls_button:
		tool_calls_list.visible = not tool_calls_list.visible
		_chat_renderer.update_tool_calls_button_label()


func _update_tool_calls_button_label() -> void:
	_chat_renderer.update_tool_calls_button_label()


func _update_tool_calls_ui() -> void:
	_chat_renderer.update_tool_calls_ui()


func _process(_delta: float) -> void:
	if _current_activity.is_empty():
		return
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - float(_current_activity.get("started_at", 0.0))
	var raw: String = _current_activity.get("text", "")
	# Show thought trail: "Previous step → Current step   elapsed" so user sees what the bot is doing.
	var line: String
	if _activity_history.size() > 0:
		var prev: Dictionary = _activity_history[_activity_history.size() - 1]
		var prev_text: String = str(prev.get("text", "")).strip_edges()
		if prev_text.is_empty():
			line = "%s   %s" % [raw, _format_elapsed(elapsed)]
		else:
			line = "%s → %s   %s" % [prev_text, raw, _format_elapsed(elapsed)]
	else:
		line = "%s   %s" % [raw, _format_elapsed(elapsed)]
	var inline := get_inline_activity_label()
	if inline != null and is_instance_valid(inline):
		inline.text = line
		inline.visible = true
	# Top label is hidden; keep it in sync for any code that still reads it, and force hidden (activity shown inline).
	if current_activity_label and is_instance_valid(current_activity_label):
		current_activity_label.text = line
		current_activity_label.visible = false


func _render_chat_log() -> void:
	_chat_renderer.render_chat_log()


func _is_output_at_bottom() -> bool:
	return _chat_renderer.is_output_at_bottom()


func _update_output_from_markdown() -> void:
	_render_chat_log()


func _format_tool_calls_summaries(tool_calls: Array) -> Array:
	return GodotAIToolRunner.format_tool_calls_summaries(tool_calls, self)


func _run_editor_actions_async(tool_calls: Array, proposal_mode: bool, trigger: String = "", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _tool_runner.run_editor_actions_async(tool_calls, proposal_mode, trigger, prompt, lint_errors_before, lint_errors_after)


func _render_changes_tab() -> void:
	if _changes_tab:
		_changes_tab.render_changes_tab()


func _show_diff(old_content: String, new_content: String) -> void:
	_changes_tab.show_diff(old_content, new_content)


func _on_pending_item_selected(index: int) -> void:
	_changes_tab.on_pending_item_selected(index)


func _on_revert_selected_pressed() -> void:
	_changes_tab.on_revert_selected_pressed()


func _on_timeline_item_selected(index: int) -> void:
	_changes_tab.on_timeline_item_selected(index)


func _read_text_res(path: String) -> String:
	return GodotAIServerLint.read_text_res(path)


func _post_lint_fix_to_backend(file_path: String, lint_output: String, old_content: String, new_content: String, prompt: String) -> void:
	await _backend_api.post_lint_fix_to_backend(file_path, lint_output, old_content, new_content, prompt)


func _lint_and_autofix_return_ok(res_path: String, max_rounds: int) -> bool:
	return await GodotAILintAutofix.lint_and_autofix_return_ok(self, res_path, max_rounds)


## Single-shot lint: run lint once (local then backend if needed). If fail, set result and send at most one follow-up. No loop. Fast.
func lint_once_then_maybe_one_follow_up(res_path: String) -> bool:
	return await _lint_once_then_maybe_one_follow_up(res_path)


func _lint_once_then_maybe_one_follow_up(res_path: String) -> bool:
	var lint := await GodotAIServerLint.run_lint(self, res_path)
	var ok := lint.get("ok", false)
	var out := str(lint.get("output", "")).strip_edges()
	set_last_lint_result(res_path, out)
	_set_status(GodotAIServerLint.format_lint_summary(ok, out))
	return ok


func _apply_editor_decorations() -> void:
	if _decorator:
		_decorator.apply_decorations()


func _log_edit_event_to_backend(edit_records: Array, trigger: String = "tool_action", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _backend_api.log_edit_event_to_backend(edit_records, trigger, prompt, lint_errors_before, lint_errors_after)


func _should_lint_path(path: String) -> bool:
	return GodotAIServerLint.should_lint_path(path)


func _lint_and_autofix(res_path: String, max_rounds: int) -> void:
	await GodotAILintAutofix.lint_and_autofix(self, res_path, max_rounds)


## Store last lint result so the next query sends it to RAG (context.extra.lint_output).
func set_last_lint_result(res_path: String, output: String) -> void:
	_last_lint_path = res_path
	_last_lint_output = output


func get_last_lint_path() -> String:
	return _last_lint_path


func get_last_lint_output() -> String:
	return _last_lint_output


func _run_editor_actions_then_lint_follow_up(
	tool_calls: Array,
	proposal_mode: bool,
	trigger: String = "",
	prompt: String = "",
	lint_errors_before: String = "",
	lint_errors_after: String = ""
) -> void:
	await _run_editor_actions_async(tool_calls, proposal_mode, trigger, prompt, lint_errors_before, lint_errors_after)


## Called by tool_runner when an edited file still has lint errors. Sends a follow-up request so the model fixes remaining errors (repeats until clean or LINT_FOLLOW_UP_CAP).
func send_lint_fix_follow_up(res_path: String, lint_output: String) -> void:
	if res_path.is_empty() or lint_output.is_empty():
		return
	if _lint_follow_up_count_this_turn >= LINT_FOLLOW_UP_CAP:
		return
	# Tools are always on; no check needed.
	_lint_follow_up_count_this_turn += 1
	set_last_lint_result(res_path, lint_output)
	_ensure_chat_has_messages()
	# Add a hidden user message so backend has thread context; UI never shows it (silent lint follow-up).
	var follow_up_msg := "Fix the remaining errors in this file."
	if _lint_follow_up_count_this_turn > 1:
		follow_up_msg = "Fix the remaining errors (round %d)." % _lint_follow_up_count_this_turn
	_chats[_current_chat]["messages"].append({"role": "user", "text": follow_up_msg, "hidden": true})
	_chats[_current_chat]["messages"].append({"role": "assistant", "text": ""})
	_tw_visible = 0
	_tw_active_chat_index = _current_chat
	_render_chat_log()
	scroll_output_to_bottom()
	call_deferred("_deferred_send_question", "Fix the remaining lint errors in this file.", true, res_path, "", lint_output)


## Lint: local (editor) first via GodotAIServerLint.run_lint; backend when available, else same-engine subprocess so we always get real error text.
func _request_backend_lint(res_path: String) -> Dictionary:
	var base := (rag_service_url as String).strip_edges().trim_suffix("/")
	if base.is_empty():
		# No backend: run Godot --script path --check-only in a subprocess and capture output (same as backend would do).
		var sub := GodotAIServerLint.run_lint_via_godot_subprocess(res_path)
		var out_text := str(sub.get("output", "")).strip_edges()
		set_last_lint_result(res_path, out_text)
		var ok := bool(sub.get("success", false))
		return {
			"success": ok,
			"message": "Lint passed" if ok else "Lint reported issues",
			"path": res_path,
			"output": out_text,
			"exit_code": int(sub.get("exit_code", -1))
		}
	var url := base + "/lint"
	var project_root_abs := ProjectSettings.globalize_path("res://")
	var body := JSON.stringify({"project_root_abs": project_root_abs, "path": res_path})
	var req := HTTPRequest.new()
	add_child(req)
	req.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	var args: Array = await req.request_completed
	req.queue_free()
	if args[0] != HTTPRequest.RESULT_SUCCESS:
		var fail_msg := "Lint request failed (is the RAG backend running?)"
		set_last_lint_result(res_path, fail_msg)
		return {"success": false, "message": fail_msg, "path": res_path, "output": fail_msg, "exit_code": -1}
	var resp_body: PackedByteArray = args[3]
	var json := JSON.new()
	if json.parse(resp_body.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		var invalid_msg := "Invalid lint response from backend"
		set_last_lint_result(res_path, invalid_msg)
		return {"success": false, "message": invalid_msg, "path": res_path, "output": invalid_msg, "exit_code": -1}
	var d: Dictionary = json.data
	var ok := bool(d.get("success", false))
	var out_text := str(d.get("output", "")).strip_edges()
	set_last_lint_result(res_path, out_text)
	return {"success": ok, "message": "Lint passed" if ok else "Lint reported issues", "path": res_path, "output": out_text, "exit_code": int(d.get("exit_code", -1))}


func _query_backend_for_tools(question: String, lint_output: String = "", override_file_path: String = "", override_file_text: String = "") -> Dictionary:
	return await _backend_api.query_backend_for_tools(question, lint_output, override_file_path, override_file_text)


func _post_system_message(text: String) -> void:
	_ensure_chat_has_messages()
	var messages: Array = _chats[_current_chat]["messages"]
	messages.append({"role": "assistant", "text": text})
	_render_chat_log()


func _append_error_to_chat(error_message: String) -> void:
	_post_system_message("**Error**\n\n" + error_message)


func _ensure_chat_has_messages() -> void:
	_chat_state.ensure_chat_has_messages()


func _ensure_default_chat() -> void:
	if _chat_state:
		_chat_state.ensure_default_chat()


func _on_new_chat_pressed() -> void:
	_chat_state.on_new_chat_pressed()
	_streamed_markdown = ""
	_ensure_chat_has_messages()
	_update_context_usage_label()
	_render_chat_log()


func _on_chat_tab_selected(tab_index: int) -> void:
	if not _streaming_in_progress:
		if _typewriter_timer != null:
			_typewriter_timer.stop()
		_tw_active_chat_index = -1
	_chat_state.on_chat_tab_selected(tab_index)
	_update_activity_ui()
	_render_chat_log()
	_update_context_usage_label()
	_update_tool_calls_ui()
	_refresh_pinned_context_row()
	if context_viewer_panel and context_viewer_panel.visible:
		_refresh_context_viewer_panel()


func _on_chat_tab_rearranged(idx_to: int) -> void:
	_chat_state.on_chat_tab_rearranged(idx_to)
	if _current_chat >= 0 and _current_chat < _chats.size():
		_render_chat_log()
		_update_context_usage_label()


func _on_chat_tab_close_pressed(tab_index: int) -> void:
	_delete_chat_at_index(tab_index)


func _delete_chat_at_index(idx: int) -> void:
	if idx < 0 or idx >= _chats.size():
		return
	var was_current := (idx == _current_chat)
	_chats.remove_at(idx)
	if chat_tab_bar and chat_tab_bar.tab_count > idx:
		chat_tab_bar.remove_tab(idx)
	if _chats.is_empty():
		if _chat_state:
			_chat_state.ensure_default_chat()
		return
	# Adjust current index: if we removed the current tab or one before it, update.
	if was_current:
		_current_chat = mini(idx, _chats.size() - 1)
	elif idx < _current_chat:
		_current_chat -= 1
	chat_tab_bar.current_tab = _current_chat
	if _chat_state:
		_chat_state.on_chat_tab_selected(_current_chat)
	_render_chat_log()
	_update_context_usage_label()
	_update_activity_ui()
	_update_tool_calls_ui()
	_update_ask_button_state()


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
	_history_tab.refresh_history()


func _refresh_history() -> void:
	_history_tab.refresh_history()


func _render_history_list() -> void:
	_history_tab.render_history_list()


func _on_history_item_selected(index: int) -> void:
	_history_tab.on_history_item_selected(index)


func _on_history_undo_pressed() -> void:
	await _history_tab.on_history_undo_pressed()


func _query_backend_json(endpoint: String, method: int, body: String) -> Variant:
	return await GodotAIBackendClient.query_json(self, endpoint, method, body)


func _refresh_settings_tab_from_config() -> void:
	if _settings_tab:
		_settings_tab.refresh_settings_tab_from_config()


func _refresh_index_and_context_status() -> void:
	_settings_tab.refresh_index_and_context_status()


func _on_index_status_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_settings_tab.on_index_status_request_completed(result, response_code, headers, body)


func _update_context_windows_ui() -> void:
	_settings_tab.update_context_windows_ui()


func _save_settings_tab_to_config() -> void:
	_settings_tab.save_settings_tab_to_config()


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
	# Tools and auto-lint are always on; no UI to sync.
	if model_option:
		var models: Array[String] = _settings.get_models_for_profile(_settings.backend_profile_id)
		model_option.clear()
		for i in range(models.size()):
			model_option.add_item(models[i], i)
		var current_model := _settings.get_effective_model()
		var idx: int = models.find(current_model)
		if idx >= 0:
			model_option.select(idx)
		else:
			model_option.select(0)
	_apply_display_settings()
	# Re-render chat so message list uses new font size / word wrap (when using chat_message_list).
	if _chat_renderer:
		_chat_renderer.render_chat_log()


func _apply_display_settings() -> void:
	_settings_tab.apply_display_settings()


func _on_model_selected(_index: int) -> void:
	if _settings and model_option and model_option.selected >= 0:
		var models: Array[String] = _settings.get_models_for_profile(_settings.backend_profile_id)
		if model_option.selected < models.size():
			if _settings.backend_profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER:
				_settings.composer_model = models[model_option.selected]
			else:
				_settings.selected_model = models[model_option.selected]
			_settings.save_settings()


func _on_follow_agent_toggled(_pressed: bool) -> void:
	if _settings and follow_agent_check:
		_settings.follow_agent = follow_agent_check.button_pressed
		_settings.save_settings()


func _on_settings_backend_selected(index: int) -> void:
	var profiles: Array = GodotAIBackendProfile.get_all_profiles()
	if index < 0 or index >= profiles.size():
		return
	var profile: GodotAIBackendProfile = profiles[index]
	if _settings:
		_settings.backend_profile_id = profile.profile_id
	if _settings_tab:
		_settings_tab.refresh_model_option_only()




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
