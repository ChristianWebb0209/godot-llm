@tool
extends RefCounted
class_name GodotAISettings

## Persists AI Assistant settings to a config file in the editor data directory.
## Call load_settings() after EditorInterface is set; use save_settings() to persist.

const CONFIG_SECTION := "godot_ai_assistant"
const KEY_TEXT_SIZE := "text_size"
const KEY_WORD_WRAP := "word_wrap"
const KEY_RAG_URL := "rag_service_url"
const KEY_PROVIDER := "provider"
const KEY_OPENAI_API_KEY := "openai_api_key"
const KEY_OPENAI_BASE_URL := "openai_base_url"
const KEY_SELECTED_MODEL := "selected_model"
const KEY_FOLLOW_AGENT := "follow_agent"
const KEY_ALLOW_EDITOR_ACTIONS := "allow_editor_actions"

const DEFAULT_TEXT_SIZE := 18
const DEFAULT_RAG_URL := "http://127.0.0.1:8000"
const DEFAULT_PROVIDER := "openai"
const DEFAULT_MODEL := "gpt-4.1-mini"
const OPENAI_MODELS: Array[String] = [
	"gpt-4.1-mini",
	"gpt-4.1-nano",
	"gpt-4o-mini",
	"gpt-4o",
	"gpt-4-turbo",
	"gpt-4",
	"o1-mini",
	"o1",
]

var _editor_interface: EditorInterface = null
var _config_path: String = ""

var text_size: int = DEFAULT_TEXT_SIZE
var word_wrap: bool = true
var rag_service_url: String = DEFAULT_RAG_URL
var provider: String = DEFAULT_PROVIDER
var openai_api_key: String = ""
var openai_base_url: String = ""
var selected_model: String = DEFAULT_MODEL
var follow_agent: bool = true
var allow_editor_actions: bool = true


func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e
	if _editor_interface:
		var paths: EditorPaths = _editor_interface.get_editor_paths()
		if paths:
			_config_path = paths.get_data_dir().path_join("godot_ai_assistant_settings.cfg")


func load_settings() -> void:
	if _config_path.is_empty():
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(_config_path)
	if err != OK:
		return
	text_size = cfg.get_value(CONFIG_SECTION, KEY_TEXT_SIZE, DEFAULT_TEXT_SIZE) as int
	word_wrap = cfg.get_value(CONFIG_SECTION, KEY_WORD_WRAP, true) as bool
	rag_service_url = cfg.get_value(CONFIG_SECTION, KEY_RAG_URL, DEFAULT_RAG_URL) as String
	provider = cfg.get_value(CONFIG_SECTION, KEY_PROVIDER, DEFAULT_PROVIDER) as String
	openai_api_key = cfg.get_value(CONFIG_SECTION, KEY_OPENAI_API_KEY, "") as String
	openai_base_url = cfg.get_value(CONFIG_SECTION, KEY_OPENAI_BASE_URL, "") as String
	selected_model = cfg.get_value(CONFIG_SECTION, KEY_SELECTED_MODEL, DEFAULT_MODEL) as String
	follow_agent = cfg.get_value(CONFIG_SECTION, KEY_FOLLOW_AGENT, true) as bool
	allow_editor_actions = cfg.get_value(CONFIG_SECTION, KEY_ALLOW_EDITOR_ACTIONS, false) as bool


func save_settings() -> void:
	if _config_path.is_empty():
		return
	var cfg := ConfigFile.new()
	cfg.set_value(CONFIG_SECTION, KEY_TEXT_SIZE, text_size)
	cfg.set_value(CONFIG_SECTION, KEY_WORD_WRAP, word_wrap)
	cfg.set_value(CONFIG_SECTION, KEY_RAG_URL, rag_service_url)
	cfg.set_value(CONFIG_SECTION, KEY_PROVIDER, provider)
	cfg.set_value(CONFIG_SECTION, KEY_OPENAI_API_KEY, openai_api_key)
	cfg.set_value(CONFIG_SECTION, KEY_OPENAI_BASE_URL, openai_base_url)
	cfg.set_value(CONFIG_SECTION, KEY_SELECTED_MODEL, selected_model)
	cfg.set_value(CONFIG_SECTION, KEY_FOLLOW_AGENT, follow_agent)
	cfg.set_value(CONFIG_SECTION, KEY_ALLOW_EDITOR_ACTIONS, allow_editor_actions)
	cfg.save(_config_path)


func get_openai_models() -> Array[String]:
	return OPENAI_MODELS
