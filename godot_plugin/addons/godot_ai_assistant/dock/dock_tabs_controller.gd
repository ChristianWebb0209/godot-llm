@tool
extends RefCounted

## Controller: wires settings/changes signals and handles main tab orchestration.
##
## Goal: keep `ai_dock.gd` focused on node refs + wiring, not on long glue blocks.

var _last_main_tab: int = 0

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func resolve_settings_controls() -> void:
	var settings_root: Node = _dock.get_node_or_null("TabContainer/Settings/Margin/Scroll/SettingsVBox")
	if not settings_root:
		return
	_dock.follow_agent_check = settings_root.get_node_or_null("AISection/FollowAgentRow/SettingsFollowAgentCheck") as CheckButton
	_dock.settings_text_size_spin = settings_root.get_node_or_null("DisplaySection/TextSizeRow/SettingsTextSizeSpin") as SpinBox
	_dock.settings_word_wrap_check = settings_root.get_node_or_null("DisplaySection/WordWrapRow/SettingsWordWrapCheck") as CheckButton
	_dock.settings_rag_url_edit = settings_root.get_node_or_null("AISection/RagUrlRow/SettingsRagUrlEdit") as LineEdit
	_dock.settings_backend_option = settings_root.get_node_or_null("AISection/BackendRow/SettingsBackendOption") as OptionButton
	_dock.settings_api_key_edit = settings_root.get_node_or_null("AISection/ApiKeyRow/SettingsApiKeyEdit") as LineEdit
	_dock.settings_base_url_edit = settings_root.get_node_or_null("AISection/BaseUrlRow/SettingsBaseUrlEdit") as LineEdit
	_dock.settings_model_option = settings_root.get_node_or_null("AISection/SettingsModelRow/SettingsModelOption") as OptionButton
	_dock.settings_save_button = settings_root.get_node_or_null("SettingsButtons/SettingsSaveButton") as Button
	_dock.refresh_indicators_button = settings_root.get_node_or_null("SettingsButtons/RefreshIndicatorsButton") as Button
	_dock.indexing_content = settings_root.get_node_or_null("IndexingSection/IndexingContent") as Label
	_dock.context_windows_list = settings_root.get_node_or_null("ContextSection/ContextWindowsList") as VBoxContainer


func wire_settings_signals() -> void:
	var st: GodotAISettingsTab = _dock.get_settings_tab()
	if not st:
		return

	if _dock.model_option:
		_dock.model_option.item_selected.connect(st.on_model_selected)
		var popup: PopupMenu = _dock.model_option.get_popup()
		if popup:
			popup.about_to_popup.connect(st.on_model_popup_about_to_popup)

	if _dock.follow_agent_check:
		_dock.follow_agent_check.toggled.connect(st.on_follow_agent_toggled)

	if _dock.settings_save_button:
		_dock.settings_save_button.pressed.connect(st.on_settings_save_pressed)

	if _dock.settings_text_size_spin:
		_dock.settings_text_size_spin.value_changed.connect(st.on_settings_changed)

	if _dock.settings_word_wrap_check:
		_dock.settings_word_wrap_check.toggled.connect(st.on_settings_changed)

	if _dock.settings_rag_url_edit:
		_dock.settings_rag_url_edit.focus_exited.connect(st.on_settings_changed)

	if _dock.settings_api_key_edit:
		_dock.settings_api_key_edit.focus_exited.connect(st.on_settings_changed)

	if _dock.settings_base_url_edit:
		_dock.settings_base_url_edit.focus_exited.connect(st.on_settings_changed)

	if _dock.settings_model_option:
		_dock.settings_model_option.item_selected.connect(st.on_settings_model_selected)

	if _dock.settings_backend_option:
		_dock.settings_backend_option.item_selected.connect(st.on_settings_backend_selected)

	if _dock.index_status_request:
		_dock.index_status_request.request_completed.connect(st.on_index_status_request_completed)

	if _dock.refresh_indicators_button:
		_dock.refresh_indicators_button.pressed.connect(st.on_refresh_indicators_pressed)


func wire_changes_signals() -> void:
	var ct: GodotAIChangesTab = _dock.get_changes_tab()
	if not ct:
		return

	if _dock.pending_list:
		_dock.pending_list.item_selected.connect(ct.on_pending_item_selected)

	if _dock.pending_accept_button:
		_dock.pending_accept_button.text = "Revert selected"
		_dock.pending_accept_button.pressed.connect(ct.on_revert_selected_pressed)

	if _dock.pending_reject_button:
		_dock.pending_reject_button.visible = false

	if _dock.timeline_list:
		_dock.timeline_list.item_selected.connect(ct.on_timeline_item_selected)
		_dock.history_list = _dock.timeline_list


func connect_main_tabs(tab_container: TabContainer) -> void:
	if not tab_container:
		return
	tab_container.tab_changed.connect(on_main_tab_changed)
	_last_main_tab = tab_container.current_tab


func on_main_tab_changed(tab_index: int) -> void:
	# Use child name so behavior is correct after user drag-reorders main tabs.
	var settings_tab_idx: int = -1
	var changes_tab_idx: int = -1

	if _dock.tab_container:
		for i in range(_dock.tab_container.get_child_count()):
			var c: Node = _dock.tab_container.get_child(i)
			if c.name == "Settings":
				settings_tab_idx = i
			elif c.name == "Changes":
				changes_tab_idx = i

		# When leaving Changes tab, clear timeline focus and diff highlights.
		if changes_tab_idx >= 0 and _last_main_tab == changes_tab_idx and tab_index != changes_tab_idx:
			_dock.get_changes_tab().unfocus_timeline_edit()

		# When leaving Settings tab, persist current UI to config so values are saved.
		if settings_tab_idx >= 0 and _last_main_tab == settings_tab_idx and tab_index != settings_tab_idx:
			_dock.get_settings_tab().save_settings_tab_to_config()

		_last_main_tab = tab_index

	if not _dock.tab_container:
		return
	if tab_index < 0 or tab_index >= _dock.tab_container.get_child_count():
		return

	var child: Node = _dock.tab_container.get_child(tab_index)
	var name_str := child.name if child else ""
	if name_str == "Settings":
		_dock.get_settings_tab().refresh_settings_tab_from_config()
	elif name_str == "Changes":
		if _dock.get_changes_tab():
			_dock.get_changes_tab().render_changes_tab()
		if _dock._history_tab:
			_dock._history_tab.refresh_usage()

