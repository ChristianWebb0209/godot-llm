@tool
extends EditorPlugin

var _dock: Control = null


func _enter_tree() -> void:
	var dock_scene = load("res://addons/godot_ai_assistant/ai_dock.tscn") as PackedScene
	if dock_scene:
		_dock = dock_scene.instantiate() as Control
		if _dock:
			_dock.set_editor_interface(get_editor_interface())
			add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

