@tool
extends RefCounted
class_name GodotAISettingsTab

## Settings tab: refresh/save config, index status, context windows UI, display settings.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func refresh_settings_tab_from_config() -> void:
	if _dock.get_settings() == null:
		return
	_dock.get_settings().load_settings()
	if _dock.settings_text_size_spin:
		_dock.settings_text_size_spin.value = _dock.get_settings().text_size
	if _dock.settings_word_wrap_check:
		_dock.settings_word_wrap_check.button_pressed = _dock.get_settings().word_wrap
	if _dock.settings_rag_url_edit:
		_dock.settings_rag_url_edit.text = _dock.get_settings().rag_service_url
	if _dock.settings_api_key_edit:
		_dock.settings_api_key_edit.text = _dock.get_settings().openai_api_key
	if _dock.settings_base_url_edit:
		_dock.settings_base_url_edit.text = _dock.get_settings().openai_base_url
	if _dock.settings_model_option:
		_dock.settings_model_option.clear()
		for i in range(_dock.get_settings().get_openai_models().size()):
			var m: String = _dock.get_settings().get_openai_models()[i]
			_dock.settings_model_option.add_item(m, i)
		var idx: int = _dock.get_settings().get_openai_models().find(_dock.get_settings().selected_model)
		if idx >= 0:
			_dock.settings_model_option.select(idx)
		else:
			_dock.settings_model_option.select(0)
	refresh_index_and_context_status()


func refresh_index_and_context_status() -> void:
	update_context_windows_ui()
	if not _dock.index_status_request:
		return
	var base := _dock.rag_service_url
	if _dock.settings_rag_url_edit:
		base = _dock.settings_rag_url_edit.text
	base = base.strip_edges()
	if base.is_empty():
		base = _dock.rag_service_url
	var project_root := ProjectSettings.globalize_path("res://").strip_edges()
	var url := base + "/index_status"
	if not project_root.is_empty():
		url += "?project_root=" + project_root.uri_encode()
	_dock.indexing_content.text = "Loading..."
	_dock.index_status_request.request(url)


func on_index_status_request_completed(
	_result: int, _response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	var json_str := body.get_string_from_utf8()
	if json_str.is_empty():
		if _dock.indexing_content:
			_dock.indexing_content.text = "Could not reach backend."
		return
	var j := JSON.new()
	if j.parse(json_str) != OK:
		if _dock.indexing_content:
			_dock.indexing_content.text = "Invalid response."
		return
	var d = j.data
	if typeof(d) != TYPE_DICTIONARY:
		if _dock.indexing_content:
			_dock.indexing_content.text = "Invalid response."
		return
	var lines: Array[String] = []
	lines.append("Chroma docs: %d chunks" % int(d.get("chroma_docs", 0)))
	lines.append("Chroma project_code: %d snippets" % int(d.get("chroma_project_code", 0)))
	var repo_err = d.get("repo_index_error", null)
	if repo_err != null and str(repo_err).strip_edges().length() > 0:
		lines.append("Repo index: %s" % str(repo_err))
	elif d.get("repo_index_files", null) != null:
		var files := int(d.get("repo_index_files", 0))
		var edges := int(d.get("repo_index_edges", 0))
		lines.append("Repo index: %d files, %d edges" % [files, edges])
	else:
		lines.append("Repo index: (send project_root for stats)")
	if _dock.indexing_content:
		_dock.indexing_content.text = "\n".join(lines)
	update_context_windows_ui()


func update_context_windows_ui() -> void:
	if not _dock.context_windows_list:
		return
	for c in _dock.context_windows_list.get_children():
		c.queue_free()
	for i in range(_dock.get_chats().size()):
		var chat: Dictionary = _dock.get_chats()[i]
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
		_dock.context_windows_list.add_child(l)


func save_settings_tab_to_config() -> void:
	if _dock.get_settings() == null:
		return
	if _dock.settings_text_size_spin:
		_dock.get_settings().text_size = int(_dock.settings_text_size_spin.value)
	if _dock.settings_word_wrap_check:
		_dock.get_settings().word_wrap = _dock.settings_word_wrap_check.button_pressed
	if _dock.settings_rag_url_edit:
		_dock.get_settings().rag_service_url = _dock.settings_rag_url_edit.text.strip_edges()
	if _dock.settings_api_key_edit:
		_dock.get_settings().openai_api_key = _dock.settings_api_key_edit.text
	if _dock.settings_base_url_edit:
		_dock.get_settings().openai_base_url = _dock.settings_base_url_edit.text.strip_edges()
	if _dock.settings_model_option and _dock.settings_model_option.selected >= 0:
		var models: Array[String] = _dock.get_settings().get_openai_models()
		if _dock.settings_model_option.selected < models.size():
			_dock.get_settings().selected_model = models[_dock.settings_model_option.selected]
	# Sync Chat-tab toggles so one Save persists everything
	if _dock.follow_agent_check:
		_dock.get_settings().follow_agent = _dock.follow_agent_check.button_pressed
	# Tools and auto-lint are always on; no UI to sync.
	_dock.get_settings().save_settings()


func apply_display_settings() -> void:
	if _dock.get_settings() == null:
		return
	var font_size: int = _dock.get_settings().text_size
	if _dock.output_text_edit:
		_dock.output_text_edit.add_theme_font_size_override("normal_font_size", font_size)
		_dock.output_text_edit.add_theme_font_size_override("mono_font_size", font_size)
		var wrap := _dock.get_settings().word_wrap
		_dock.output_text_edit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	if _dock.prompt_text_edit:
		_dock.prompt_text_edit.add_theme_font_size_override("font_size", font_size)
		_dock.prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if wrap else TextEdit.LINE_WRAPPING_NONE
