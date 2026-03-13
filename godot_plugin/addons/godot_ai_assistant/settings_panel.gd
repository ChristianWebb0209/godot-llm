@tool
extends PopupPanel
class_name GodotAISettingsPanel

## Settings UI: Display (text size, word wrap) and AI (provider, API key, base URL).
## Persists via GodotAISettings; notifies parent to apply and save.

signal settings_saved()

@onready var text_size_spin: SpinBox = %TextSizeSpinBox
@onready var word_wrap_check: CheckButton = %WordWrapCheck
@onready var rag_url_edit: LineEdit = %RagUrlEdit
@onready var provider_option: OptionButton = %ProviderOption
@onready var api_key_edit: LineEdit = %ApiKeyEdit
@onready var base_url_edit: LineEdit = %BaseUrlEdit
@onready var model_option: OptionButton = %ModelOption
@onready var save_button: Button = %SaveButton

var _settings: GodotAISettings = null


func set_settings(s: GodotAISettings) -> void:
	_settings = s


func _ready() -> void:
	if save_button:
		save_button.pressed.connect(_on_save_pressed)
	popup_hide.connect(_on_popup_hide)


func open_with_current_settings() -> void:
	if _settings == null:
		return
	_settings.load_settings()
	_apply_to_ui()
	popup_centered_ratio(0.5)


func _apply_to_ui() -> void:
	if text_size_spin:
		text_size_spin.value = _settings.text_size
	if word_wrap_check:
		word_wrap_check.button_pressed = _settings.word_wrap
	if rag_url_edit:
		rag_url_edit.text = _settings.rag_service_url
	if provider_option:
		provider_option.clear()
		provider_option.add_item("OpenAI", 0)
		provider_option.select(0)
	if api_key_edit:
		api_key_edit.text = _settings.openai_api_key
		api_key_edit.secret = true
	if base_url_edit:
		base_url_edit.text = _settings.openai_base_url
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


func _read_from_ui() -> void:
	if _settings == null:
		return
	if text_size_spin:
		_settings.text_size = int(text_size_spin.value)
	if word_wrap_check:
		_settings.word_wrap = word_wrap_check.button_pressed
	if rag_url_edit:
		_settings.rag_service_url = rag_url_edit.text.strip_edges()
	if api_key_edit:
		_settings.openai_api_key = api_key_edit.text
	if base_url_edit:
		_settings.openai_base_url = base_url_edit.text.strip_edges()
	if model_option and model_option.selected >= 0:
		var models: Array[String] = _settings.get_openai_models()
		if model_option.selected < models.size():
			_settings.selected_model = models[model_option.selected]


func _on_save_pressed() -> void:
	_read_from_ui()
	if _settings:
		_settings.save_settings()
	settings_saved.emit()
	hide()


func _on_popup_hide() -> void:
	# Optional: save on close even without clicking Save
	pass
