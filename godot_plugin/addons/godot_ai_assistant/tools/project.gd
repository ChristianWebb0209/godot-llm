@tool
extends RefCounted
class_name GodotAIProject

## Read project.godot: get_project_settings, get_autoloads, get_input_map (client fallback when server did not run).

static func execute_get_project_settings(executor: GodotAIEditorToolExecutor, _output: Dictionary) -> Dictionary:
	var path: String = ProjectSettings.globalize_path("res://project.godot")
	if path.is_empty():
		return {"success": false, "message": "Project path not available."}
	var cfg := ConfigFile.new()
	var err: Error = cfg.load(path)
	if err != OK:
		return {"success": false, "message": "Failed to load project.godot."}
	var sections: Dictionary = {}
	var keys: PackedStringArray = cfg.get_section_keys("")
	for section in cfg.get_sections():
		sections[section] = {}
		for key in cfg.get_section_keys(section):
			var val = cfg.get_value(section, key)
			sections[section][key] = str(val)
	return {
		"success": true,
		"message": "Project settings (project.godot).",
		"sections": sections,
	}


static func execute_get_autoloads(executor: GodotAIEditorToolExecutor, _output: Dictionary) -> Dictionary:
	var autoloads: Array = []
	var path: String = ProjectSettings.globalize_path("res://project.godot")
	if not path.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(path) == OK and cfg.has_section("autoload"):
			for key in cfg.get_section_keys("autoload"):
				var val: String = str(cfg.get_value("autoload", key, ""))
				autoloads.append({"name": key, "path": val})
	return {
		"success": true,
		"message": "Autoloads from project.godot.",
		"autoloads": autoloads,
	}


static func execute_get_input_map(executor: GodotAIEditorToolExecutor, _output: Dictionary) -> Dictionary:
	var actions: Array = []
	var path: String = ProjectSettings.globalize_path("res://project.godot")
	if not path.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(path) == OK and cfg.has_section("input"):
			for key in cfg.get_section_keys("input"):
				actions.append({"action": key})
	return {
		"success": true,
		"message": "Input map from project.godot.",
		"input_map": actions,
	}
