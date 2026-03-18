@tool
extends RefCounted
class_name GodotAISettings

## Persists AI Assistant settings to a config file in the user's app data (same location
## as Godot editor config: e.g. %APPDATA%\Godot on Windows). Does not rely on EditorPaths;
## path is built from OS so it works even when editor paths are unavailable.
## Call load_settings() when the plugin opens; use save_settings() to persist.

const CONFIG_SECTION := "godot_ai_assistant"
const CONFIG_FILENAME := "godot_ai_assistant_settings.cfg"
const KEY_TEXT_SIZE := "text_size"
const KEY_WORD_WRAP := "word_wrap"
const KEY_RAG_URL := "rag_service_url"
const KEY_PROVIDER := "provider"
const KEY_OPENAI_API_KEY := "openai_api_key"
const KEY_OPENAI_BASE_URL := "openai_base_url"
const KEY_SELECTED_MODEL := "selected_model"
const KEY_BACKEND_PROFILE := "backend_profile_id"
const KEY_COMPOSER_MODEL := "composer_model"
const KEY_FOLLOW_AGENT := "follow_agent"
const KEY_ALLOW_EDITOR_ACTIONS := "allow_editor_actions"
const KEY_AUTO_LINT_AFTER_EDIT := "auto_lint_after_edit"

const DEFAULT_TEXT_SIZE := 18
const DEFAULT_RAG_URL := "http://127.0.0.1:8000"
const DEFAULT_PROVIDER := "openai"
const DEFAULT_MODEL := "gpt-4.1-mini"
const DEFAULT_BACKEND_PROFILE := "rag"
const DEFAULT_COMPOSER_MODEL := "godot-composer"
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
## Model id used when backend is Godot Composer (fine-tuned tool-use model).
const COMPOSER_MODELS: Array[String] = [
	"godot-composer",
	"Qwen/Qwen2.5-Coder-7B-Instruct-Godot-Tools",
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
var backend_profile_id: String = DEFAULT_BACKEND_PROFILE
var composer_model: String = DEFAULT_COMPOSER_MODEL
var follow_agent: bool = false
var allow_editor_actions: bool = true
var auto_lint_after_edit: bool = true


func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e
	if _editor_interface:
		var paths: EditorPaths = _editor_interface.get_editor_paths()
		if paths:
			var dir: String = paths.get_data_dir()
			if not dir.is_empty():
				_config_path = dir.path_join(CONFIG_FILENAME)


## Returns the path to the settings file. Prefers EditorPaths when set; otherwise uses
## OS-specific app data so storage works without relying on editor lifecycle.
func _get_config_path() -> String:
	if not _config_path.is_empty():
		return _config_path
	var base_dir: String = ""
	if OS.get_name() == "Windows":
		base_dir = OS.get_environment("APPDATA")
		if base_dir.is_empty():
			base_dir = OS.get_environment("USERPROFILE").path_join("AppData").path_join("Roaming")
		base_dir = base_dir.path_join("Godot")
	elif OS.get_name() == "macOS":
		var home: String = OS.get_environment("HOME")
		if home.is_empty():
			home = "~/"
		base_dir = home.path_join("Library").path_join("Application Support").path_join("Godot")
	else:
		# Linux/BSD: XDG_CONFIG_HOME or ~/.config
		base_dir = OS.get_environment("XDG_CONFIG_HOME")
		if base_dir.is_empty():
			var home: String = OS.get_environment("HOME")
			if home.is_empty():
				home = "~/"
			base_dir = home.path_join(".config")
		base_dir = base_dir.path_join("godot")
	if base_dir.is_empty():
		return ""
	_config_path = base_dir.path_join(CONFIG_FILENAME)
	return _config_path


func load_settings() -> void:
	var path := _get_config_path()
	if path.is_empty():
		return
	if not FileAccess.file_exists(path):
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		return
	text_size = cfg.get_value(CONFIG_SECTION, KEY_TEXT_SIZE, DEFAULT_TEXT_SIZE) as int
	word_wrap = cfg.get_value(CONFIG_SECTION, KEY_WORD_WRAP, true) as bool
	rag_service_url = cfg.get_value(CONFIG_SECTION, KEY_RAG_URL, DEFAULT_RAG_URL) as String
	provider = cfg.get_value(CONFIG_SECTION, KEY_PROVIDER, DEFAULT_PROVIDER) as String
	openai_api_key = cfg.get_value(CONFIG_SECTION, KEY_OPENAI_API_KEY, "") as String
	openai_base_url = cfg.get_value(CONFIG_SECTION, KEY_OPENAI_BASE_URL, "") as String
	selected_model = cfg.get_value(CONFIG_SECTION, KEY_SELECTED_MODEL, DEFAULT_MODEL) as String
	backend_profile_id = cfg.get_value(CONFIG_SECTION, KEY_BACKEND_PROFILE, DEFAULT_BACKEND_PROFILE) as String
	composer_model = cfg.get_value(CONFIG_SECTION, KEY_COMPOSER_MODEL, DEFAULT_COMPOSER_MODEL) as String
	follow_agent = cfg.get_value(CONFIG_SECTION, KEY_FOLLOW_AGENT, false) as bool
	allow_editor_actions = cfg.get_value(CONFIG_SECTION, KEY_ALLOW_EDITOR_ACTIONS, true) as bool
	auto_lint_after_edit = cfg.get_value(CONFIG_SECTION, KEY_AUTO_LINT_AFTER_EDIT, true) as bool


func save_settings() -> void:
	var path := _get_config_path()
	if path.is_empty():
		return
	var dir_path: String = path.get_base_dir()
	if not dir_path.is_empty():
		DirAccess.make_dir_recursive_absolute(dir_path)
	var cfg := ConfigFile.new()
	cfg.set_value(CONFIG_SECTION, KEY_TEXT_SIZE, text_size)
	cfg.set_value(CONFIG_SECTION, KEY_WORD_WRAP, word_wrap)
	cfg.set_value(CONFIG_SECTION, KEY_RAG_URL, rag_service_url)
	cfg.set_value(CONFIG_SECTION, KEY_PROVIDER, provider)
	cfg.set_value(CONFIG_SECTION, KEY_OPENAI_API_KEY, openai_api_key)
	cfg.set_value(CONFIG_SECTION, KEY_OPENAI_BASE_URL, openai_base_url)
	cfg.set_value(CONFIG_SECTION, KEY_SELECTED_MODEL, selected_model)
	cfg.set_value(CONFIG_SECTION, KEY_BACKEND_PROFILE, backend_profile_id)
	cfg.set_value(CONFIG_SECTION, KEY_COMPOSER_MODEL, composer_model)
	cfg.set_value(CONFIG_SECTION, KEY_FOLLOW_AGENT, follow_agent)
	cfg.set_value(CONFIG_SECTION, KEY_ALLOW_EDITOR_ACTIONS, allow_editor_actions)
	cfg.set_value(CONFIG_SECTION, KEY_AUTO_LINT_AFTER_EDIT, auto_lint_after_edit)
	cfg.save(path)


func get_openai_models() -> Array[String]:
	return OPENAI_MODELS


## Returns the model list for the given backend profile (RAG = OpenAI models, Composer = fine-tuned model ids).
func get_models_for_profile(profile_id: String) -> Array[String]:
	if profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER:
		return COMPOSER_MODELS
	return OPENAI_MODELS


## Effective model id for the current backend profile.
func get_effective_model() -> String:
	if backend_profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER:
		return composer_model
	return selected_model
