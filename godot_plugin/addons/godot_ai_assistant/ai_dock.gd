@tool
extends Control
class_name GodotAIDock

## Godot AI Assistant — Dock view composition root.
##
## MVC boundary:
## - This file is the **View + Composition Root**: node refs, signal wiring, and delegating to helpers.
## - Avoid adding business logic here. If a method grows beyond “wiring”, extract it into:
##   - Stores: `core/*`, `core/stores/*` (pure state)
##   - Controllers/services: `dock/*`, `chat/*`, `backend/*`, `tools/*`, `editor/*`, `services/*` (side effects)
##
## Velocity rule: keep this file shrinking toward the 1000-line cap.

const _LOG_PREFIX := "[AI Assistant] "

@onready var tab_container: TabContainer = $TabContainer
@onready var chat_tab_bar: TabBar = $TabContainer/Chat/VBox/ChatTabBarRow/ChatTabBarPanel/ChatTabBar
var context_usage_bar: ProgressBar = null  # Optional; removed from UI (was animated context indicator)
@onready var new_chat_button: Button = $TabContainer/Chat/VBox/ChatTabBarRow/NewChatButton
@onready var current_activity_label: Label = $TabContainer/Chat/VBox/ActivityBlock/CurrentActivityLabel
@onready var thought_history_button: Button = $TabContainer/Chat/VBox/ActivityBlock/ThoughtHistoryButton
@onready var thought_history_list: VBoxContainer = $TabContainer/Chat/VBox/ActivityBlock/ThoughtHistoryList
@onready var tool_calls_button: Button = $TabContainer/Chat/VBox/ActivityBlock/ToolCallsButton
@onready var tool_calls_list: VBoxContainer = $TabContainer/Chat/VBox/ActivityBlock/ToolCallsList
@onready var chat_scroll: ScrollContainer = $TabContainer/Chat/VBox/IOContainer/ChatScroll
@onready var chat_message_list: VBoxContainer = $TabContainer/Chat/VBox/IOContainer/ChatScroll/ChatMessageList
var output_text_edit: RichTextLabel = null  # Optional: used only when chat_message_list is missing (fallback)
@onready var prompt_text_edit: TextEdit = $TabContainer/Chat/VBox/IOContainer/PromptRow/ChatInputBar/PromptTextEdit
@onready var model_option: OptionButton = $TabContainer/Chat/VBox/IOContainer/PromptRow/ChatInputBar/ModelOption
@onready var ask_button: Button = $TabContainer/Chat/VBox/IOContainer/PromptRow/ChatInputBar/AskButton
var follow_agent_check: CheckButton = null  # Set in _ready from Settings tab (optional)
@onready var context_viewer_button: Button = $TabContainer/Chat/VBox/BottomRow/ToolRow/ContextViewerButton
@onready var io_container: VSplitContainer = $TabContainer/Chat/VBox/IOContainer
@onready var pinned_context_row: HBoxContainer = $TabContainer/Chat/VBox/IOContainer/PinnedContextRow
@onready var context_viewer_panel: VBoxContainer = $TabContainer/Chat/VBox/ContextViewerPanel
@onready var context_viewer_list: VBoxContainer = $TabContainer/Chat/VBox/ContextViewerPanel/ContextViewerScroll/ContextViewerList
@onready var context_viewer_empty_label: Label = $TabContainer/Chat/VBox/ContextViewerPanel/ContextViewerEmptyLabel
var status_label: Label = null  # Optional: StatusLabel removed from UI
@onready var http_request: HTTPRequest = $HTTPRequest
@onready var history_usage_label: Label = $TabContainer/Changes/Margin/ChangesVBox/HistoryUsageVBox/HistoryUsageLabel
var settings_text_size_spin: SpinBox = null
var settings_word_wrap_check: CheckButton = null
var settings_rag_url_edit: LineEdit = null
var settings_backend_option: OptionButton = null
var settings_api_key_edit: LineEdit = null
var settings_base_url_edit: LineEdit = null
var settings_model_option: OptionButton = null
var settings_save_button: Button = null
var refresh_indicators_button: Button = null
var indexing_content: Label = null
var context_windows_list: VBoxContainer = null
@onready var index_status_request: HTTPRequest = $IndexStatusRequest

@onready var pending_list: ItemList = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/PendingList
@onready var pending_accept_button: Button = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/PendingButtonsRow/PendingAcceptButton
@onready var pending_reject_button: Button = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/PendingButtonsRow/PendingRejectButton
@onready var timeline_list: ItemList = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/TimelineList
@onready var history_scroll: ScrollContainer = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/HistoryScroll
@onready var history_list_vbox: VBoxContainer = $TabContainer/Changes/Margin/ChangesVBox/ChangesSplit/LeftVBox/HistoryScroll/HistoryListVBox

# History tab (RAG) uses history_list when custom rows disabled; history_list_vbox for custom +x/-y/time-ago rows.
var history_list: ItemList = null
var history_detail_label: RichTextLabel = null

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
var _diff_review: GodotAIDiffReview = null
var _backend_api: GodotAIBackendAPI = null
var _tool_runner: GodotAIToolRunner = null
var _chat_state: GodotAIChatState = null
var _chat_renderer: GodotAIChatRenderer = null
var _activity_state: GodotAIActivityState = null
var _changes_tab: GodotAIChangesTab = null
var _history_tab: GodotAIHistoryTab = null
var _settings_tab: GodotAISettingsTab = null
var _lint_service: GodotAILintService = null
var _pinned_context: GodotAIPinnedContext = null
var _chat_context_menu_ctrl: GodotAIChatContextMenu = null
var _context_viewer: GodotAIContextViewer = null
var _chat_streaming: GodotAIChatStreaming = null
var _http_handler: GodotAIHttpRequestHandler = null
var _tool_follow_up: GodotAIToolFollowUp = null
var _editor_chrome: GodotAIEditorChrome = null
var _chat_ux: GodotAIChatUX = null
var _history_events: Array = []
var _selected_history_edit_id: int = -1
var _ask_icon_idle: Texture2D = null
var _ask_icon_busy: Texture2D = null
var _selected_pending_id: String = ""
var _selected_timeline_id: String = ""
var _last_tool_prompt: String = ""
var _last_tool_trigger: String = "tool_action"
var _chat_session_store: GodotAIChatSessionStore = null

# Each chat: { title, messages, context_usage, prompt_draft, current_activity, activity_history }
# When _agent_store is set, it is the single source of truth (shared with Agent Manager main screen).
var _agent_store: GodotAIAgentStore = null
var _chats: Array = []
var _current_chat: int = -1
var _active_chat_view: Control = null  # Optional: when set, render/activity go here (e.g. Agent Manager panel)
const _SCROLL_AT_BOTTOM_THRESHOLD: float = 25.0

# Current chat's activity (synced with _chats[i] when switching tabs)
var _current_activity: Dictionary = {}  # Legacy; prefer _chat_session_store.current_activity
var _activity_history: Array = []  # Legacy; prefer _chat_session_store.activity_history
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
# When true, we do not auto-scroll during streaming; re-cleared when user sends a new message.
var _user_scrolled_away: bool = false # Legacy; prefer _chat_session_store.user_scrolled_away
# True while our tween is moving the scroll bar so we don't treat it as user scroll.
var _scroll_was_programmatic: bool = false # Legacy; prefer _chat_session_store.scroll_was_programmatic
# Right-click context menu on chat: which message index was right-clicked (-1 = none).
var _context_menu_message_index: int = -1
var _chat_context_menu: PopupMenu = null
var _export_file_dialog: EditorFileDialog = null
const _TYPEWRITER_CHARS_PER_TICK := 5

# Last lint result (client or backend) so the next query can send it to RAG as context.
var _last_lint_path: String = ""
var _last_lint_output: String = ""
# Re-run lint after edits and send follow-up until clean or cap (so we fix all errors, not just the first).
const LINT_FOLLOW_UP_CAP := 5
var _lint_follow_up_count_this_turn: int = 0
var _last_main_tab: int = 0

func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e
	_tool_executor = GodotAIEditorToolExecutor.new(e) if e else null
	_settings = GodotAISettings.new()
	_settings.set_editor_interface(e)
	_edit_store = GodotAIEditStore.new()
	_edit_store.load_from_disk()
	if _chat_session_store == null:
		_chat_session_store = GodotAIChatSessionStore.new()
	_decorator = GodotAIEditorDecorator.new(e, _edit_store)
	_diff_review = GodotAIDiffReview.new(e)
	_backend_api = GodotAIBackendAPI.new(self)
	_tool_runner = GodotAIToolRunner.new(self)
	_chat_state = GodotAIChatState.new(self)
	_chat_renderer = GodotAIChatRenderer.new(self)
	_activity_state = GodotAIActivityState.new(self)
	_changes_tab = GodotAIChangesTab.new(self)
	_history_tab = GodotAIHistoryTab.new(self)
	_settings_tab = GodotAISettingsTab.new(self)
	_lint_service = GodotAILintService.new()
	_pinned_context = GodotAIPinnedContext.new(self)
	_chat_context_menu_ctrl = GodotAIChatContextMenu.new(self)
	_context_viewer = GodotAIContextViewer.new(self)
	_chat_streaming = GodotAIChatStreaming.new(self)
	_http_handler = GodotAIHttpRequestHandler.new(self)
	_tool_follow_up = GodotAIToolFollowUp.new(self)
	_editor_chrome = GodotAIEditorChrome.new(self)
	_chat_ux = GodotAIChatUX.new(self)
	if _editor_interface:
		var base := _editor_interface.get_base_control()
		if base:
			_ask_icon_idle = base.get_theme_icon("Play", "EditorIcons")
			_ask_icon_busy = base.get_theme_icon("Reload", "EditorIcons")


# Public API for modules (avoids private-access errors from helper scripts)
func get_editor_interface() -> EditorInterface:
	return _editor_interface

func get_diff_review() -> Variant:
	return _diff_review

func get_agent_store() -> GodotAIAgentStore:
	return _agent_store

func set_agent_store(store: GodotAIAgentStore) -> void:
	_agent_store = store
	if _agent_store:
		_agent_store.chats_changed.connect(_sync_tab_bar_from_store)
		_agent_store.current_chat_changed.connect(_on_store_current_chat_changed)
		_agent_store.ensure_default_chat()
		# Sync after dock is in tree so chat_tab_bar is ready
		call_deferred("_sync_tab_bar_from_store")

func get_chats() -> Array:
	return _agent_store.get_chats() if _agent_store else _chats

func set_chats_arr(a: Array) -> void:
	if _agent_store:
		_agent_store.set_chats(a)
	else:
		_chats = a

func get_current_chat() -> int:
	return _agent_store.get_current_index() if _agent_store else _current_chat

func set_current_chat_index(i: int) -> void:
	if _agent_store:
		_agent_store.set_current_index(i)
	else:
		_current_chat = i

## Generate a stable unique id for a new chat (used for OpenViking session memory).
func generate_chat_id() -> String:
	if _agent_store:
		return _agent_store.generate_chat_id()
	return "c_%d_%d" % [Time.get_ticks_msec(), randi() % 1000000]


func _sync_tab_bar_from_store() -> void:
	if not _agent_store or not chat_tab_bar:
		return
	var arr: Array = _agent_store.get_chats()
	chat_tab_bar.clear_tabs()
	for c in arr:
		if typeof(c) == TYPE_DICTIONARY:
			chat_tab_bar.add_tab(str(c.get("title", "Chat")))
	var cur := _agent_store.get_current_index()
	if cur >= 0 and cur < chat_tab_bar.tab_count:
		chat_tab_bar.current_tab = cur
	_sync_ui_from_current_chat()


func _on_store_current_chat_changed() -> void:
	if not _agent_store or not chat_tab_bar:
		return
	var cur := _agent_store.get_current_index()
	if cur >= 0 and cur < chat_tab_bar.tab_count:
		chat_tab_bar.current_tab = cur
	_sync_ui_from_current_chat()
	_chat_ux.update_ask_button_state()


func _sync_ui_from_current_chat() -> void:
	var arr: Array = get_chats()
	var cur: int = get_current_chat()
	if cur < 0 or cur >= arr.size():
		return
	var chat: Dictionary = arr[cur] if typeof(arr[cur]) == TYPE_DICTIONARY else {}
	if prompt_text_edit:
		prompt_text_edit.text = str(chat.get("prompt_draft", ""))
	set_current_activity_dict((chat.get("current_activity", {}) as Dictionary).duplicate())
	set_activity_history_arr((chat.get("activity_history", []) as Array).duplicate())
	set_streamed_markdown("")
	var messages: Array = chat.get("messages", [])
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		set_streamed_markdown(messages[messages.size() - 1].get("text", ""))

## Return the current chat's stable id, or empty string if none (for backend context.extra.chat_id).
func get_current_chat_id() -> String:
	var chats_arr: Array = get_chats()
	var cur: int = get_current_chat()
	if cur < 0 or cur >= chats_arr.size():
		return ""
	var c = chats_arr[cur]
	if typeof(c) != TYPE_DICTIONARY:
		return ""
	var id_val = c.get("id", "")
	return str(id_val) if id_val else ""


func get_settings() -> GodotAISettings:
	return _settings

func get_edit_store() -> GodotAIEditStore:
	return _edit_store

func get_chat_renderer() -> GodotAIChatRenderer:
	return _chat_renderer

func get_changes_tab() -> GodotAIChangesTab:
	return _changes_tab

func get_settings_tab() -> GodotAISettingsTab:
	return _settings_tab

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
	if _chat_session_store:
		return _chat_session_store.current_activity
	return _current_activity

func set_current_activity_dict(d: Dictionary) -> void:
	if _chat_session_store:
		_chat_session_store.set_current_activity(d)
	else:
		_current_activity = d

func get_activity_history() -> Array:
	if _chat_session_store:
		return _chat_session_store.activity_history
	return _activity_history

func set_activity_history_arr(a: Array) -> void:
	if _chat_session_store:
		_chat_session_store.set_activity_history(a)
	else:
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

func append_error_to_chat(msg: String) -> void:
	_append_error_to_chat(msg)

func get_pending_http_kind() -> StringName:
	return _pending_http_kind

func set_pending_http_kind(kind: StringName) -> void:
	_pending_http_kind = kind

func clear_pending_http_kind() -> void:
	_pending_http_kind = &""

func handle_backend_health_response(data: Dictionary) -> void:
	var status_val: Variant = data.get("status", "")
	if typeof(status_val) == TYPE_STRING and String(status_val) == "ok":
		_set_status("Backend ready.")
	else:
		_set_status("Backend reachable, unexpected /health response.")

func handle_backend_query_response(data: Dictionary) -> void:
	var answer: String = data.get("answer", "")
	var usage_raw = data.get("context_usage", null)
	if typeof(usage_raw) == TYPE_DICTIONARY and get_current_chat() >= 0 and get_current_chat() < get_chats().size():
		get_chats()[get_current_chat()]["context_usage"] = usage_raw
		_chat_ux.update_context_usage_label()
		if context_viewer_panel and context_viewer_panel.visible:
			_refresh_context_viewer_panel()
	var tool_calls_raw = data.get("tool_calls", [])
	_ensure_chat_has_messages()
	var cur_chat_index: int = get_current_chat()
	var messages: Array = get_chats()[cur_chat_index]["messages"]
	var parsed := _parse_think_and_answer(answer)
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		messages[messages.size() - 1]["reasoning"] = parsed.reasoning
		messages[messages.size() - 1]["text"] = parsed.answer
	else:
		messages.append({"role": "assistant", "reasoning": parsed.reasoning, "text": parsed.answer})
	_maybe_update_chat_title_from_answer(cur_chat_index)
	_streamed_markdown = ""
	_tw_visible = 0
	_tw_active_chat_index = get_current_chat()
	_chat_renderer.render_chat_log()
	if _typewriter_timer != null:
		_typewriter_timer.start()
	_set_status("Response received.")
	if tool_calls_raw is Array and tool_calls_raw.size() > 0:
		var summaries: Array = _format_tool_calls_summaries(tool_calls_raw)
		if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
			messages[messages.size() - 1]["tool_calls_summary"] = summaries
		_chat_renderer.update_tool_calls_ui()
		if _tool_executor:
			if _tool_follow_up == null:
				_tool_follow_up = GodotAIToolFollowUp.new(self)
			_tool_follow_up.run_editor_actions_then_lint_follow_up.call_deferred(
				tool_calls_raw,
				false,
				"tool_action",
				_last_tool_prompt,
				"",
				""
			)
	else:
		clear_activity()

func get_lint_follow_up_cap() -> int:
	return LINT_FOLLOW_UP_CAP

func get_lint_follow_up_count_this_turn() -> int:
	return _lint_follow_up_count_this_turn

func increment_lint_follow_up_count() -> void:
	_lint_follow_up_count_this_turn += 1

func reset_typewriter_for_current_chat() -> void:
	_tw_visible = 0
	_tw_active_chat_index = get_current_chat()

func push_activity(line: String) -> void:
	_push_activity(line)


func clear_activity() -> void:
	_clear_activity()
	_set_status("")

func request_backend_lint(res_path: String) -> Dictionary:
	if _lint_service == null:
		_lint_service = GodotAILintService.new()
	return await _lint_service.request_backend_lint(self, rag_service_url, res_path)

func query_backend_for_tools(
	question: String,
	lint_output: String = "",
	override_file_path: String = "",
	override_file_text: String = ""
) -> Dictionary:
	return await _backend_api.query_backend_for_tools(question, lint_output, override_file_path, override_file_text)

func run_editor_actions_async(tool_calls: Array, proposal_mode: bool, trigger: String = "", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _run_editor_actions_async(tool_calls, proposal_mode, trigger, prompt, lint_errors_before, lint_errors_after)
	
func post_system_message(text: String) -> void:
	_post_system_message(text)

func ensure_chat_has_messages() -> void:
	_ensure_chat_has_messages()

func ensure_chat_has_messages_internal() -> void:
	# For helper modules. Prefer ensure_chat_has_messages() when possible.
	_ensure_chat_has_messages()

func get_chat_context_menu() -> PopupMenu:
	return _chat_context_menu

func set_context_menu_message_index(i: int) -> void:
	_context_menu_message_index = i

func get_context_menu_message_index() -> int:
	return _context_menu_message_index

func get_export_file_dialog() -> EditorFileDialog:
	return _export_file_dialog

func render_chat_log() -> void:
	_chat_renderer.render_chat_log()

func apply_editor_decorations() -> void:
	_apply_editor_decorations()

func escape_bbcode(t: String) -> String:
	return _escape_bbcode(t)

func query_backend_json(endpoint: String, method: int, body: String) -> Variant:
	return await _query_backend_json(endpoint, method, body)

func should_lint_path(path: String) -> bool:
	return GodotAIServerLint.should_lint_path(path)

func log_edit_event_to_backend(
	edit_records: Array,
	trigger: String = "tool_action",
	prompt: String = "",
	lint_errors_before: String = "",
	lint_errors_after: String = ""
) -> void:
	await _backend_api.log_edit_event_to_backend(edit_records, trigger, prompt, lint_errors_before, lint_errors_after)


func _set_status(t: String) -> void:
	if status_label:
		status_label.text = t


func _ready() -> void:
	print("AI Assistant: _ready called on dock")
	# Use the layout from the scene; let Godot's dock system drive our size.
	# Auto-focus prompt when user clicks onto the dock or switches to Chat tab.
	focus_mode = Control.FOCUS_ALL
	focus_entered.connect(func() -> void:
		if _chat_ux == null:
			_chat_ux = GodotAIChatUX.new(self)
		_chat_ux.on_dock_focus_entered()
	)
	if tab_container:
		tab_container.focus_entered.connect(func() -> void:
			if _chat_ux == null:
				_chat_ux = GodotAIChatUX.new(self)
			_chat_ux.on_dock_focus_entered()
		)
		tab_container.focus_exited.connect(func() -> void:
			if _chat_ux == null:
				_chat_ux = GodotAIChatUX.new(self)
			_chat_ux.on_dock_focus_exited()
		)
	if _typewriter_timer == null:
		_typewriter_timer = Timer.new()
		_typewriter_timer.wait_time = 0.028
		_typewriter_timer.timeout.connect(_on_typewriter_timer_timeout)
		add_child(_typewriter_timer)
	output_text_edit = get_node_or_null("TabContainer/Chat/VBox/IOContainer/OutputText") as RichTextLabel
	status_label = get_node_or_null("TabContainer/Chat/VBox/BottomRow/StatusLabel") as Label
	var settings_root: Node = get_node_or_null("TabContainer/Settings/Margin/Scroll/SettingsVBox")
	if settings_root:
		follow_agent_check = settings_root.get_node_or_null("AISection/FollowAgentRow/SettingsFollowAgentCheck") as CheckButton
		settings_text_size_spin = settings_root.get_node_or_null("DisplaySection/TextSizeRow/SettingsTextSizeSpin") as SpinBox
		settings_word_wrap_check = settings_root.get_node_or_null("DisplaySection/WordWrapRow/SettingsWordWrapCheck") as CheckButton
		settings_rag_url_edit = settings_root.get_node_or_null("AISection/RagUrlRow/SettingsRagUrlEdit") as LineEdit
		settings_backend_option = settings_root.get_node_or_null("AISection/BackendRow/SettingsBackendOption") as OptionButton
		settings_api_key_edit = settings_root.get_node_or_null("AISection/ApiKeyRow/SettingsApiKeyEdit") as LineEdit
		settings_base_url_edit = settings_root.get_node_or_null("AISection/BaseUrlRow/SettingsBaseUrlEdit") as LineEdit
		settings_model_option = settings_root.get_node_or_null("AISection/SettingsModelRow/SettingsModelOption") as OptionButton
		settings_save_button = settings_root.get_node_or_null("SettingsButtons/SettingsSaveButton") as Button
		refresh_indicators_button = settings_root.get_node_or_null("SettingsButtons/RefreshIndicatorsButton") as Button
		indexing_content = settings_root.get_node_or_null("IndexingSection/IndexingContent") as Label
		context_windows_list = settings_root.get_node_or_null("ContextSection/ContextWindowsList") as VBoxContainer
	if output_text_edit:
		output_text_edit.bbcode_enabled = true
		if output_text_edit.resized.is_connected(_chat_renderer.render_chat_log) == false:
			output_text_edit.resized.connect(_chat_renderer.render_chat_log)
	if ask_button:
		ask_button.text = ""
		ask_button.flat = false
		ask_button.custom_minimum_size = Vector2(32, 32)
		ask_button.pressed.connect(_chat_streaming.on_ask_pressed)
		_chat_ux.update_ask_button_state()
	else:
		print("AI Assistant: ask_button is null")
	if prompt_text_edit:
		# Keep the input a fixed single-row height; let long placeholder/text overflow horizontally.
		prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
		prompt_text_edit.scroll_fit_content_height = false
		prompt_text_edit.scroll_past_end_of_file = false
		prompt_text_edit.gui_input.connect(func(event: InputEvent) -> void:
			if _chat_ux == null:
				_chat_ux = GodotAIChatUX.new(self)
			_chat_ux.on_prompt_text_edit_gui_input(event)
		)
		prompt_text_edit.text_changed.connect(_chat_ux.update_ask_button_state)

	if http_request:
		http_request.request_completed.connect(_http_handler.on_http_request_completed)
	else:
		print("AI Assistant: http_request is null")

	if new_chat_button:
		new_chat_button.pressed.connect(_on_new_chat_pressed)
	if chat_tab_bar:
		chat_tab_bar.drag_to_rearrange_enabled = true
		chat_tab_bar.tab_selected.connect(_on_chat_tab_selected)
		if chat_tab_bar.has_signal("active_tab_rearranged"):
			chat_tab_bar.active_tab_rearranged.connect(_on_chat_tab_rearranged)
		if chat_tab_bar.has_signal("tab_close_pressed"):
			chat_tab_bar.tab_close_pressed.connect(_chat_state.on_chat_tab_close_pressed)
		if _editor_chrome == null:
			_editor_chrome = GodotAIEditorChrome.new(self)
		_editor_chrome.apply_chat_tab_bar_editor_style()
	if model_option:
		model_option.item_selected.connect(_settings_tab.on_model_selected)
		var popup := model_option.get_popup()
		if popup:
			popup.about_to_popup.connect(_settings_tab.on_model_popup_about_to_popup)
	if follow_agent_check:
		follow_agent_check.toggled.connect(_settings_tab.on_follow_agent_toggled)
	if tab_container:
		tab_container.tab_changed.connect(_on_main_tab_changed)
		# Enable drag-to-reorder on main tabs (Chat, History, Settings)
		var main_tab_bar: TabBar = tab_container.get_tab_bar()
		if main_tab_bar:
			main_tab_bar.drag_to_rearrange_enabled = true
		# Clear, readable tab labels; Settings is furthest right by default (tab order in scene)
		if tab_container.get_tab_count() >= 3:
			tab_container.set_tab_title(0, "Chat")
			tab_container.set_tab_title(1, "History")
			tab_container.set_tab_title(2, "Settings")
	if settings_save_button:
		settings_save_button.pressed.connect(_settings_tab.on_settings_save_pressed)
	# Auto-save and apply whenever any setting changes (persist to OS config immediately).
	if settings_text_size_spin:
		settings_text_size_spin.value_changed.connect(_settings_tab.on_settings_changed)
	if settings_word_wrap_check:
		settings_word_wrap_check.toggled.connect(_settings_tab.on_settings_changed)
	if settings_rag_url_edit:
		settings_rag_url_edit.focus_exited.connect(_settings_tab.on_settings_changed)
	if settings_api_key_edit:
		settings_api_key_edit.focus_exited.connect(_settings_tab.on_settings_changed)
	if settings_base_url_edit:
		settings_base_url_edit.focus_exited.connect(_settings_tab.on_settings_changed)
	if settings_model_option:
		settings_model_option.item_selected.connect(_settings_tab.on_settings_model_selected)
	if settings_backend_option:
		settings_backend_option.item_selected.connect(_settings_tab.on_settings_backend_selected)
	if index_status_request:
		index_status_request.request_completed.connect(_settings_tab.on_index_status_request_completed)
	if refresh_indicators_button:
		refresh_indicators_button.pressed.connect(_settings_tab.on_refresh_indicators_pressed)
	if pending_list:
		pending_list.item_selected.connect(_changes_tab.on_pending_item_selected)
	if pending_accept_button:
		pending_accept_button.text = "Revert selected"
		pending_accept_button.pressed.connect(_changes_tab.on_revert_selected_pressed)
	if pending_reject_button:
		pending_reject_button.visible = false
	if timeline_list:
		timeline_list.item_selected.connect(_changes_tab.on_timeline_item_selected)
		history_list = timeline_list
	if thought_history_button:
		thought_history_button.pressed.connect(_on_thought_history_toggled)
	if tool_calls_button:
		tool_calls_button.pressed.connect(_on_tool_calls_toggled)
	# Activity (Thinking... / Tool call: X) is shown inline at bottom of chat, not at top.
	if current_activity_label:
		current_activity_label.visible = false
	if context_viewer_button:
		context_viewer_button.pressed.connect(_on_context_viewer_button_pressed)
	if chat_scroll and chat_message_list:
		chat_scroll.resized.connect(_update_chat_message_list_min_width)
		call_deferred("_update_chat_message_list_min_width")
		chat_message_list.add_theme_constant_override("separation", 12)
		chat_scroll.gui_input.connect(_chat_context_menu_ctrl.on_chat_gui_input)
		var vbar: VScrollBar = chat_scroll.get_v_scroll_bar()
		if vbar != null:
			vbar.value_changed.connect(_on_chat_scroll_value_changed)
	_chat_context_menu = PopupMenu.new()
	_chat_context_menu.id_pressed.connect(_chat_context_menu_ctrl.on_menu_id_pressed)
	add_child(_chat_context_menu)
	_export_file_dialog = EditorFileDialog.new()
	_export_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_export_file_dialog.add_filter("Text file (*.txt)", "*.txt")
	_export_file_dialog.add_filter("Markdown (*.md)", "*.md")
	_export_file_dialog.title = "Export chat"
	_export_file_dialog.file_selected.connect(_chat_context_menu_ctrl.export_chat_to_path)
	add_child(_export_file_dialog)

	if _settings_tab:
		_settings_tab.apply_settings_from_config()
	_chat_ux.update_context_usage_label()
	if _chat_state:
		_chat_state.ensure_default_chat()
		_chat_state.update_chat_tab_close_visibility()
	_refresh_pinned_context_row()
	if _settings_tab:
		_settings_tab.refresh_settings_tab_from_config()
	if tab_container:
		_last_main_tab = tab_container.current_tab
	if _http_handler == null:
		_http_handler = GodotAIHttpRequestHandler.new(self)
	_http_handler.start_health_check()
	if _changes_tab:
		_changes_tab.render_changes_tab()
	if _editor_chrome == null:
		_editor_chrome = GodotAIEditorChrome.new(self)
	_editor_chrome.start_decoration_refresh()
	# Deferred so editor docks (FileSystem, Script, Scene) are built; then retry once after a short delay.
	call_deferred("_apply_editor_decorations")
	var late_timer := Timer.new()
	late_timer.wait_time = 0.6
	late_timer.one_shot = true
	late_timer.timeout.connect(_apply_editor_decorations)
	add_child(late_timer)
	late_timer.start()


# Editor chrome extracted to GodotAIEditorChrome (tab bar style + decoration refresh timer).


func _focus_prompt_for_interject() -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.focus_prompt_input()


# Focus behavior implemented in GodotAIChatUX.





## Send a message as the current chat (used by Agent Manager or other views). Caller clears their prompt.
func send_user_message(question: String) -> void:
	if _chat_streaming == null:
		_chat_streaming = GodotAIChatStreaming.new(self)
	_chat_streaming.send_user_message(question)


func get_current_chat_exclude_context_keys() -> Array:
	if get_current_chat() < 0 or get_current_chat() >= get_chats().size():
		return []
	return (get_chats()[get_current_chat()].get("exclude_context_keys", []) as Array).duplicate()


## Drag-to-context: add items from editor drag data (FileSystem files, Scene tree nodes, script tabs, or script selection text).
func add_pinned_context_from_drag_data(data: Variant) -> void:
	if _pinned_context == null:
		_pinned_context = GodotAIPinnedContext.new(self)
	_pinned_context.add_from_drag_data(data)


func _pinned_context_contains(pinned: Array, entry: Dictionary) -> bool:
	# Legacy wrapper (kept temporarily for compatibility while refactoring).
	if _pinned_context == null:
		_pinned_context = GodotAIPinnedContext.new(self)
	return _pinned_context.contains_entry(pinned, entry)


func get_current_chat_pinned_context() -> Array:
	if _pinned_context == null:
		_pinned_context = GodotAIPinnedContext.new(self)
	return _pinned_context.get_current()


func remove_pinned_context(chat_index: int, entry_index: int) -> void:
	if _pinned_context == null:
		_pinned_context = GodotAIPinnedContext.new(self)
	_pinned_context.remove_entry(chat_index, entry_index)


func _build_pinned_context_extra() -> Dictionary:
	if _pinned_context == null:
		_pinned_context = GodotAIPinnedContext.new(self)
	return _pinned_context.build_extra()


func _refresh_pinned_context_row() -> void:
	if _pinned_context == null:
		_pinned_context = GodotAIPinnedContext.new(self)
	_pinned_context.refresh_row()


func get_current_chat_conversation_messages() -> Array:
	if get_current_chat() < 0 or get_current_chat() >= get_chats().size():
		return []
	return get_chats()[get_current_chat()].get("messages", [])


func _deferred_send_question(
	question: String,
	use_tools: bool,
	override_file_path: String = "",
	override_file_text: String = "",
	lint_output_override: String = ""
) -> void:
	if _chat_streaming == null:
		_chat_streaming = GodotAIChatStreaming.new(self)
	_chat_streaming.deferred_send_question(question, use_tools, override_file_path, override_file_text, lint_output_override)






func _copy_message_at_index(msg_index: int) -> void:
	if _chat_context_menu_ctrl == null:
		_chat_context_menu_ctrl = GodotAIChatContextMenu.new(self)
	_chat_context_menu_ctrl.copy_message_at_index(msg_index)


func _copy_whole_chat() -> void:
	if _chat_context_menu_ctrl == null:
		_chat_context_menu_ctrl = GodotAIChatContextMenu.new(self)
	_chat_context_menu_ctrl.copy_whole_chat()




func _is_stream_cancelled() -> bool:
	return _stream_generation != _stream_start_generation


## Parse streamed content into reasoning (think block) and answer. Returns { reasoning: String, answer: String }.
func _parse_think_and_answer(raw: String) -> Dictionary:
	# Backwards-compat wrapper.
	if _chat_streaming == null:
		_chat_streaming = GodotAIChatStreaming.new(self)
	return _chat_streaming.parse_think_and_answer(raw)


func _async_stream_request(endpoint: String, _headers: PackedStringArray, body: String) -> void:
	if _chat_streaming == null:
		_chat_streaming = GodotAIChatStreaming.new(self)
	await _chat_streaming.async_stream_request(endpoint, body)


func _on_stream_chunk(delta: String) -> void:
	if _chat_streaming == null:
		_chat_streaming = GodotAIChatStreaming.new(self)
	_chat_streaming.on_stream_chunk(delta)


func _on_stream_done(full_text: String, error_message: String = "") -> void:
	if _chat_streaming == null:
		_chat_streaming = GodotAIChatStreaming.new(self)
	_chat_streaming.on_stream_done(full_text, error_message)




func _update_chat_message_list_min_width() -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.update_chat_message_list_min_width()




func _on_context_viewer_button_pressed() -> void:
	if _context_viewer == null:
		_context_viewer = GodotAIContextViewer.new(self)
	_context_viewer.toggle()


func _refresh_context_viewer_panel() -> void:
	if _context_viewer == null:
		_context_viewer = GodotAIContextViewer.new(self)
	_context_viewer.refresh()


func _toggle_exclude_context_block(block_key: String) -> void:
	if _context_viewer == null:
		_context_viewer = GodotAIContextViewer.new(self)
	_context_viewer.toggle_exclude(block_key)


func _escape_bbcode(t: String) -> String:
	return GodotAIChatRenderer.escape_bbcode(t)


func scroll_output_to_bottom() -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.scroll_output_to_bottom()


## Only smooth-scroll to bottom if the user hasn't scrolled away. Used during streaming/typewriter.
func scroll_output_to_bottom_if_following() -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.scroll_output_to_bottom_if_following()


func _on_chat_scroll_value_changed(_value: float) -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.on_chat_scroll_value_changed()


func _deferred_smooth_scroll_chat_to_bottom() -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	await _chat_ux.deferred_smooth_scroll_chat_to_bottom()


## Called deferred after an "ask feedback" panel is added to the chat. Unrolls the panel and staggers option buttons; then scrolls to show the panel.
func _animate_ask_panel_in(panel: Control) -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.animate_ask_panel_in(panel)


func should_typewriter_assistant_at_index(idx: int) -> bool:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	return _chat_ux.should_typewriter_assistant_at_index(idx)


func get_typewriter_reasoning_slice(reasoning: String) -> String:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	return _chat_ux.get_typewriter_reasoning_slice(reasoning)


func get_typewriter_plain_slice(full_text: String, reasoning_length: int = 0) -> String:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	return _chat_ux.get_typewriter_plain_slice(full_text, reasoning_length)


func _on_typewriter_timer_timeout() -> void:
	if _chat_ux == null:
		_chat_ux = GodotAIChatUX.new(self)
	_chat_ux.on_typewriter_timer_timeout()


func _save_current_chat_activity() -> void:
	_activity_state.save_current_chat_activity()


func _push_activity(line: String) -> void:
	_activity_state.push_activity(line)


func _clear_activity() -> void:
	_activity_state.clear_activity()


func _format_elapsed(sec: float) -> String:
	return GodotAIActivityState.format_elapsed(sec)




func _on_thought_history_toggled() -> void:
	if thought_history_list:
		thought_history_list.visible = not thought_history_list.visible
	var hist := get_activity_history()
	if thought_history_button and hist.size() > 0:
		var suffix := " v" if thought_history_list.visible else " >"
		thought_history_button.text = "Thought history (%d)" % hist.size() + suffix


func _on_tool_calls_toggled() -> void:
	if tool_calls_list and tool_calls_button:
		tool_calls_list.visible = not tool_calls_list.visible
		_chat_renderer.update_tool_calls_button_label()




func _process(_delta: float) -> void:
	# When on Changes tab and user deselected the timeline (no selection but we had one), clear focus.
	if tab_container and timeline_list and not _selected_timeline_id.is_empty():
		var idx := tab_container.current_tab
		if idx >= 0 and idx < tab_container.get_child_count() and tab_container.get_child(idx).name == "Changes":
			if timeline_list.get_selected_items().is_empty():
				_changes_tab.unfocus_timeline_edit()
	if get_current_activity().is_empty():
		return
	var act := get_current_activity()
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - float(act.get("started_at", 0.0))
	var raw: String = act.get("text", "")
	# Show thought trail: "Previous step -> Current step   elapsed" so user sees what the bot is doing.
	var line: String
	var hist := get_activity_history()
	if hist.size() > 0:
		var prev: Dictionary = hist[hist.size() - 1]
		var prev_text: String = str(prev.get("text", "")).strip_edges()
		if prev_text.is_empty():
			line = "%s   %s" % [raw, _format_elapsed(elapsed)]
		else:
			line = "%s -> %s   %s" % [prev_text, raw, _format_elapsed(elapsed)]
	else:
		line = "%s   %s" % [raw, _format_elapsed(elapsed)]
	if _streaming_in_progress and _streaming_chat_index == get_current_chat():
		line += "   (Esc to interrupt)"
	var inline := get_inline_activity_label()
	if inline != null and is_instance_valid(inline):
		inline.text = line
		inline.visible = true
	# Top label is hidden; keep it in sync for any code that still reads it, and force hidden (activity shown inline).
	if current_activity_label and is_instance_valid(current_activity_label):
		current_activity_label.text = line
		current_activity_label.visible = false




func _is_output_at_bottom() -> bool:
	return _chat_renderer.is_output_at_bottom()


func _update_output_from_markdown() -> void:
	_chat_renderer.render_chat_log()


func _format_tool_calls_summaries(tool_calls: Array) -> Array:
	return GodotAIToolRunner.format_tool_calls_summaries(tool_calls, self)


func _derive_chat_title_from_first_answer(chat_index: int) -> String:
	if chat_index < 0 or chat_index >= get_chats().size():
		return ""
	var chat: Variant = get_chats()[chat_index]
	if typeof(chat) != TYPE_DICTIONARY:
		return ""
	var messages: Array = chat.get("messages", [])
	for msg in messages:
		if typeof(msg) != TYPE_DICTIONARY:
			continue
		if str(msg.get("role", "")) != "assistant":
			continue
		var text: String = str(msg.get("text", "")).strip_edges()
		if text.is_empty():
			continue
		var first_line: String = text.split("\n")[0].strip_edges()
		if first_line.is_empty():
			continue
		if first_line.length() > 60:
			first_line = first_line.substr(0, 57) + "…"
		return first_line
	return ""


func _maybe_update_chat_title_from_answer(chat_index: int) -> void:
	if chat_index < 0 or chat_index >= get_chats().size():
		return
	var chats_arr: Array = get_chats()
	var chat: Variant = chats_arr[chat_index]
	if typeof(chat) != TYPE_DICTIONARY:
		return
	var old_title: String = str(chat.get("title", ""))
	# Only auto-rename default "Chat N" style titles so we don't overwrite user-edited ones.
	if not old_title.begins_with("Chat"):
		return
	var new_title: String = _derive_chat_title_from_first_answer(chat_index)
	if new_title.is_empty():
		return
	chat["title"] = new_title
	if _agent_store:
		_agent_store.chats_changed.emit()
	elif chat_tab_bar and chat_index >= 0 and chat_index < chat_tab_bar.tab_count:
		chat_tab_bar.set_tab_title(chat_index, new_title)


func _run_editor_actions_async(tool_calls: Array, proposal_mode: bool, trigger: String = "", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _tool_runner.run_editor_actions_async(tool_calls, proposal_mode, trigger, prompt, lint_errors_before, lint_errors_after)


func _render_changes_tab() -> void:
	if _changes_tab:
		_changes_tab.render_changes_tab()





func _apply_editor_decorations() -> void:
	if _decorator:
		_decorator.apply_decorations()


func _log_edit_event_to_backend(edit_records: Array, trigger: String = "tool_action", prompt: String = "", lint_errors_before: String = "", lint_errors_after: String = "") -> void:
	await _backend_api.log_edit_event_to_backend(edit_records, trigger, prompt, lint_errors_before, lint_errors_after)


func _should_lint_path(path: String) -> bool:
	return GodotAIServerLint.should_lint_path(path)


## Store last lint result so the next query sends it to RAG (context.extra.lint_output).
func set_last_lint_result(res_path: String, output: String) -> void:
	_last_lint_path = res_path
	_last_lint_output = output


func get_last_lint_path() -> String:
	return _last_lint_path


func get_last_lint_output() -> String:
	return _last_lint_output


## Called by tool_runner when an edited file still has lint errors. Sends a follow-up request so the model fixes remaining errors (repeats until clean or LINT_FOLLOW_UP_CAP).
func send_lint_fix_follow_up(res_path: String, lint_output: String) -> void:
	if _tool_follow_up == null:
		_tool_follow_up = GodotAIToolFollowUp.new(self)
	_tool_follow_up.send_lint_fix_follow_up(res_path, lint_output)


## Lint: local (editor) first via GodotAIServerLint.run_lint; backend when available, else same-engine subprocess so we always get real error text.
func _request_backend_lint(res_path: String) -> Dictionary:
	if _lint_service == null:
		_lint_service = GodotAILintService.new()
	return await _lint_service.request_backend_lint(self, rag_service_url, res_path)


func _query_backend_for_tools(question: String, lint_output: String = "", override_file_path: String = "", override_file_text: String = "") -> Dictionary:
	return await _backend_api.query_backend_for_tools(question, lint_output, override_file_path, override_file_text)


func _post_system_message(text: String) -> void:
	_ensure_chat_has_messages()
	var messages: Array = get_chats()[get_current_chat()]["messages"]
	messages.append({"role": "assistant", "text": text})
	_chat_renderer.render_chat_log()


func _append_error_to_chat(error_message: String) -> void:
	_post_system_message("**Error**\n\n" + error_message)


func _ensure_chat_has_messages() -> void:
	_chat_state.ensure_chat_has_messages()


func _ensure_default_chat() -> void:
	if _chat_state:
		_chat_state.ensure_default_chat()


func _on_new_chat_pressed() -> void:
	_chat_state.on_new_chat_pressed()
	_chat_state.update_chat_tab_close_visibility()
	_streamed_markdown = ""
	_ensure_chat_has_messages()
	_chat_ux.update_context_usage_label()
	_chat_renderer.render_chat_log()


func _on_chat_tab_selected(tab_index: int) -> void:
	if not _streaming_in_progress:
		if _typewriter_timer != null:
			_typewriter_timer.stop()
		_tw_active_chat_index = -1
	_chat_state.on_chat_tab_selected(tab_index)
	_activity_state.update_activity_ui()
	_chat_renderer.render_chat_log()
	_chat_ux.update_context_usage_label()
	_chat_renderer.update_tool_calls_ui()
	_refresh_pinned_context_row()
	if context_viewer_panel and context_viewer_panel.visible:
		_refresh_context_viewer_panel()


func _on_chat_tab_rearranged(idx_to: int) -> void:
	_chat_state.on_chat_tab_rearranged(idx_to)
	if get_current_chat() >= 0 and get_current_chat() < get_chats().size():
		_chat_renderer.render_chat_log()
		_chat_ux.update_context_usage_label()





func _on_main_tab_changed(tab_index: int) -> void:
	# Use child name so behavior is correct after user drag-reorders main tabs.
	var settings_tab_idx: int = -1
	var changes_tab_idx: int = -1
	if tab_container:
		for i in range(tab_container.get_child_count()):
			var c: Node = tab_container.get_child(i)
			if c.name == "Settings":
				settings_tab_idx = i
			elif c.name == "Changes":
				changes_tab_idx = i
		# When leaving Changes tab, clear timeline focus and diff highlights.
		if changes_tab_idx >= 0 and _last_main_tab == changes_tab_idx and tab_index != changes_tab_idx:
			_changes_tab.unfocus_timeline_edit()
		# When leaving Settings tab, persist current UI to config so values are saved.
		if settings_tab_idx >= 0 and _last_main_tab == settings_tab_idx and tab_index != settings_tab_idx:
			_settings_tab.save_settings_tab_to_config()
		_last_main_tab = tab_index
	if tab_container and tab_index >= 0 and tab_index < tab_container.get_child_count():
		var child: Node = tab_container.get_child(tab_index)
		var name_str := child.name if child else ""
		if name_str == "Settings":
			_settings_tab.refresh_settings_tab_from_config()
		elif name_str == "Changes":
			if _changes_tab:
				_changes_tab.render_changes_tab()
			if _history_tab:
				_history_tab.refresh_usage()


func _query_backend_json(endpoint: String, method: int, body: String) -> Variant:
	return await GodotAIBackendClient.query_json(self, endpoint, method, body)


## Call after settings are saved from elsewhere (e.g. Agent Manager) so dock reloads and updates display.
func notify_settings_saved() -> void:
	if _settings_tab:
		_settings_tab.apply_settings_from_config()







# Health check extracted to GodotAIHttpRequestHandler.start_health_check()
