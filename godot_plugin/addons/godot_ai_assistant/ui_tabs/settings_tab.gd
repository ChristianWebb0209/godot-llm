@tool
extends RefCounted
class_name GodotAISettingsTab

## Settings tab: refresh/save config, index status, context windows UI, display settings.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func _ctrl(key: String):
	match key:
		"text_size_spin": return _dock.settings_text_size_spin
		"word_wrap_check": return _dock.settings_word_wrap_check
		"rag_url_edit": return _dock.settings_rag_url_edit
		"backend_option": return _dock.settings_backend_option
		"api_key_edit": return _dock.settings_api_key_edit
		"base_url_edit": return _dock.settings_base_url_edit
		"model_option": return _dock.settings_model_option
		"follow_agent_check": return _dock.follow_agent_check
		"indexing_content": return _dock.indexing_content
		"context_windows_list": return _dock.context_windows_list
	return null


func refresh_settings_tab_from_config() -> void:
	if _dock.get_settings() == null:
		return
	_dock.get_settings().load_settings()
	var spin = _ctrl("text_size_spin")
	if spin is SpinBox:
		(spin as SpinBox).value = _dock.get_settings().text_size
	var wrap_c = _ctrl("word_wrap_check")
	if wrap_c is CheckButton:
		(wrap_c as CheckButton).button_pressed = _dock.get_settings().word_wrap
	var rag = _ctrl("rag_url_edit")
	if rag is LineEdit:
		(rag as LineEdit).text = _dock.get_settings().rag_service_url
	var backend = _ctrl("backend_option")
	if backend is OptionButton:
		var ob := backend as OptionButton
		ob.clear()
		var profiles: Array = GodotAIBackendProfile.get_all_profiles()
		for i in range(profiles.size()):
			var p: GodotAIBackendProfile = profiles[i]
			ob.add_item(p.display_name, i)
		var current_id: String = _dock.get_settings().backend_profile_id
		var profile_idx: int = 0
		for i in range(profiles.size()):
			if (profiles[i] as GodotAIBackendProfile).profile_id == current_id:
				profile_idx = i
				break
		ob.select(profile_idx)
	var api = _ctrl("api_key_edit")
	if api is LineEdit:
		(api as LineEdit).text = _dock.get_settings().openai_api_key
	var base = _ctrl("base_url_edit")
	if base is LineEdit:
		(base as LineEdit).text = _dock.get_settings().openai_base_url
	var follow = _ctrl("follow_agent_check")
	if follow is CheckButton:
		(follow as CheckButton).button_pressed = _dock.get_settings().follow_agent
	refresh_model_option_only()
	refresh_index_and_context_status()


## Repopulate only the model dropdown from current backend profile (e.g. after user changes Backend).
func refresh_model_option_only() -> void:
	var ob = _ctrl("model_option")
	if not (ob is OptionButton):
		return
	var opt := ob as OptionButton
	var models: Array[String] = _dock.get_settings().get_models_for_profile(_dock.get_settings().backend_profile_id)
	opt.clear()
	for i in range(models.size()):
		opt.add_item(models[i], i)
	var current_model: String = _dock.get_settings().get_effective_model()
	var idx: int = models.find(current_model)
	if idx >= 0:
		opt.select(idx)
	else:
		opt.select(0)


func refresh_index_and_context_status() -> void:
	update_context_windows_ui()
	var loading_txt := "Loading..."
	if _dock.indexing_content:
		_dock.indexing_content.text = loading_txt
	var idx_content = _ctrl("indexing_content")
	if idx_content is Label:
		(idx_content as Label).text = loading_txt
	if not _dock.index_status_request:
		return
	var base: String = _dock.rag_service_url
	var rag_edit = _ctrl("rag_url_edit")
	if rag_edit is LineEdit:
		base = (rag_edit as LineEdit).text
	base = base.strip_edges()
	if base.is_empty():
		base = _dock.rag_service_url.strip_edges()
	if base.is_empty() or not base.begins_with("http"):
		if _dock.indexing_content:
			_dock.indexing_content.text = "Set RAG service URL (e.g. http://127.0.0.1:8000) to check index."
		if idx_content is Label:
			(idx_content as Label).text = "Set RAG service URL to check index."
		return
	var project_root := ProjectSettings.globalize_path("res://").strip_edges()
	var url: String = base + ("index_status" if base.ends_with("/") else "/index_status")
	if not project_root.is_empty():
		url += "?project_root=" + project_root.uri_encode()
	# Only request when URL is absolute (Godot HTTPRequest rejects path-only URLs).
	if url.is_empty() or not url.begins_with("http"):
		return
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
	var txt := "\n".join(lines)
	if _dock.indexing_content:
		_dock.indexing_content.text = txt
	var idx_content = _ctrl("indexing_content")
	if idx_content is Label:
		(idx_content as Label).text = txt
	update_context_windows_ui()


func update_context_windows_ui() -> void:
	var list_node = _ctrl("context_windows_list")
	if not (list_node is VBoxContainer):
		return
	var list: VBoxContainer = list_node as VBoxContainer
	for c in list.get_children():
		c.queue_free()
	for i in range(_dock.get_chats().size()):
		var chat: Dictionary = _dock.get_chats()[i]
		var title: String = chat.get("title", "Chat %d" % (i + 1))
		var messages: Array = chat.get("messages", [])
		var usage: Dictionary = chat.get("context_usage", {})
		var est: int = int(usage.get("estimated_prompt_tokens", 0))
		var limit: int = int(usage.get("limit_tokens", 0))
		var pct: float = float(usage.get("percent", 0.0))
		var usage_str := "-"
		if limit > 0 and est > 0:
			usage_str = "%d tokens (~%d%%)" % [est, int(pct * 100.0)]
		elif est > 0:
			usage_str = "%d tokens" % est
		var line := "%s: %d messages, %s" % [title, messages.size(), usage_str]
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", 12)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(l)


func save_settings_tab_to_config() -> void:
	if _dock.get_settings() == null:
		return
	var spin = _ctrl("text_size_spin")
	if spin is SpinBox:
		_dock.get_settings().text_size = int((spin as SpinBox).value)
	var wrap_c = _ctrl("word_wrap_check")
	if wrap_c is CheckButton:
		_dock.get_settings().word_wrap = (wrap_c as CheckButton).button_pressed
	var rag = _ctrl("rag_url_edit")
	if rag is LineEdit:
		_dock.get_settings().rag_service_url = (rag as LineEdit).text.strip_edges()
	var api = _ctrl("api_key_edit")
	if api is LineEdit:
		_dock.get_settings().openai_api_key = (api as LineEdit).text
	var base = _ctrl("base_url_edit")
	if base is LineEdit:
		_dock.get_settings().openai_base_url = (base as LineEdit).text.strip_edges()
	var model_ob = _ctrl("model_option")
	if model_ob is OptionButton and (model_ob as OptionButton).selected >= 0:
		var models: Array[String] = _dock.get_settings().get_models_for_profile(_dock.get_settings().backend_profile_id)
		var mob := model_ob as OptionButton
		if mob.selected < models.size():
			if _dock.get_settings().backend_profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER:
				_dock.get_settings().composer_model = models[mob.selected]
			else:
				_dock.get_settings().selected_model = models[mob.selected]
	var follow = _ctrl("follow_agent_check")
	if follow is CheckButton:
		_dock.get_settings().follow_agent = (follow as CheckButton).button_pressed
	_dock.get_settings().save_settings()


func apply_display_settings() -> void:
	if _dock.get_settings() == null:
		return
	var font_size: int = _dock.get_settings().text_size
	var wrap: bool = _dock.get_settings().word_wrap
	if _dock.output_text_edit:
		_dock.output_text_edit.add_theme_font_size_override("normal_font_size", font_size)
		_dock.output_text_edit.add_theme_font_size_override("mono_font_size", font_size)
		_dock.output_text_edit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	if _dock.prompt_text_edit:
		_dock.prompt_text_edit.add_theme_font_size_override("font_size", font_size)


func apply_settings_from_config() -> void:
	if _dock.get_settings() == null:
		return
	_dock.get_settings().load_settings()
	_dock.rag_service_url = _dock.get_settings().rag_service_url
	var follow = _ctrl("follow_agent_check")
	if follow is CheckButton:
		(follow as CheckButton).button_pressed = _dock.get_settings().follow_agent
	var model_ob = _ctrl("model_option")
	if model_ob is OptionButton:
		var opt := model_ob as OptionButton
		var models: Array[String] = _dock.get_settings().get_models_for_profile(_dock.get_settings().backend_profile_id)
		opt.clear()
		for i in range(models.size()):
			opt.add_item(models[i], i)
		var current_model := _dock.get_settings().get_effective_model()
		var idx: int = models.find(current_model)
		if idx >= 0:
			opt.select(idx)
		else:
			opt.select(0)
	apply_display_settings()
	if _dock.get_chat_renderer():
		_dock.get_chat_renderer().render_chat_log()

func on_settings_changed(_value: Variant = null) -> void:
	save_settings_tab_to_config()
	apply_settings_from_config()

func on_settings_model_selected(_index: int) -> void:
	on_settings_changed(null)

func on_settings_save_pressed() -> void:
	save_settings_tab_to_config()
	apply_settings_from_config()
	if _dock.tab_container:
		_dock.tab_container.current_tab = 0
	_dock.set_status("Settings saved.")

func on_refresh_indicators_pressed() -> void:
	if _dock.get_decorator():
		_dock.get_decorator().debug_diagnostic = true
		_dock.get_decorator().apply_decorations()
		_dock.get_decorator().debug_diagnostic = false
		_dock.set_status("Indicators refreshed. See Output for diagnostic.")
	else:
		_dock.set_status("Decorator not available.")

func on_model_selected(_index: int) -> void:
	if _dock.get_settings() and _dock.model_option and _dock.model_option.selected >= 0:
		var models: Array[String] = _dock.get_settings().get_models_for_profile(_dock.get_settings().backend_profile_id)
		if _dock.model_option.selected < models.size():
			if _dock.get_settings().backend_profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER:
				_dock.get_settings().composer_model = models[_dock.model_option.selected]
			else:
				_dock.get_settings().selected_model = models[_dock.model_option.selected]
			_dock.get_settings().save_settings()

func on_follow_agent_toggled(_pressed: bool) -> void:
	if _dock.get_settings() and _dock.follow_agent_check:
		_dock.get_settings().follow_agent = _dock.follow_agent_check.button_pressed
		_dock.get_settings().save_settings()

func on_settings_backend_selected(index: int) -> void:
	var profiles: Array = GodotAIBackendProfile.get_all_profiles()
	if index < 0 or index >= profiles.size():
		return
	var profile: GodotAIBackendProfile = profiles[index]
	if _dock.get_settings():
		_dock.get_settings().backend_profile_id = profile.profile_id
	refresh_model_option_only()
	save_settings_tab_to_config()
	apply_settings_from_config()

func on_model_popup_about_to_popup() -> void:
	if _dock.model_option == null:
		return
	var popup := _dock.model_option.get_popup()
	if popup == null:
		return
	# Let Godot compute popup size first, then reposition it so it appears above the model button.
	await _dock.get_tree().process_frame
	if _dock.model_option == null or popup == null:
		return
	var global_pos: Vector2 = _dock.model_option.get_global_position()
	var popup_size: Vector2 = popup.size
	popup.position = Vector2i(global_pos.x, int(global_pos.y - popup_size.y))
