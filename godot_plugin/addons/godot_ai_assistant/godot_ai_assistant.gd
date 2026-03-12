@tool
extends EditorPlugin

var _dock


func _enter_tree():
	# Load the AI dock scene and add it to the editor.
	var dock_scene = load("res://addons/godot_ai_assistant/ai_dock.tscn")
	if dock_scene:
		_dock = dock_scene.instantiate()
		add_control_to_bottom_panel(_dock, "AI Assistant")


func _exit_tree():
	if _dock:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null

