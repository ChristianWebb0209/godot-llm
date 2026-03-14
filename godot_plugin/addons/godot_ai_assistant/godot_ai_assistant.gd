@tool
extends EditorPlugin

var _dock: Control = null


func _enter_tree() -> void:
	var dock_scene: PackedScene = load("res://addons/godot_ai_assistant/ai_dock.tscn") as PackedScene
	if not dock_scene:
		push_error("Godot AI Assistant: Failed to load ai_dock.tscn")
		_add_fallback_dock()
		return
	_dock = dock_scene.instantiate() as Control
	if not _dock:
		push_error("Godot AI Assistant: Failed to instantiate dock scene. Check ai_dock.gd and scene for errors.")
		_add_fallback_dock()
		return
	_dock.set_editor_interface(get_editor_interface())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _add_fallback_dock() -> void:
	var panel := PanelContainer.new()
	var label := Label.new()
	label.text = "Godot AI Assistant failed to load.\nCheck Output/Debugger for errors (e.g. ai_dock.gd or ai_dock.tscn)."
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(label)
	_dock = panel
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
