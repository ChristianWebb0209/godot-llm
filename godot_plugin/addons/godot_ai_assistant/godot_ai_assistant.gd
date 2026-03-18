@tool
extends EditorPlugin

## Godot AI Assistant — EditorPlugin entrypoint.
##
## Instantiates `ui/ai_surface.tscn` twice (dock + main screen) and shares a single
## `GodotAIAgentStore` between them so both surfaces show the same chats/state.

var _agent_store: GodotAIAgentStore = null
var _dock: Control = null
var _main_screen_panel: Control = null
var _context_menu_plugins: Array = []

const _SURFACE_SCENE := preload("res://addons/godot_ai_assistant/ui/ai_surface.tscn")


func _enter_tree() -> void:
	_agent_store = GodotAIAgentStore.new()
	_agent_store.ensure_default_chat()

	if not _SURFACE_SCENE:
		push_error("Godot AI Assistant: Failed to preload ai_surface.tscn")
		_add_fallback_dock()
		return
	_dock = (_SURFACE_SCENE as PackedScene).instantiate() as Control
	if not _dock:
		push_error("Godot AI Assistant: Failed to instantiate surface scene. Check ui/ai_surface.gd and .tscn for errors.")
		_add_fallback_dock()
		return
	_dock.set_editor_interface(get_editor_interface())
	if _dock is GodotAISurface:
		(_dock as GodotAISurface).layout_variant = GodotAISurface.LayoutVariant.DOCK
	if _dock is GodotAIDock:
		(_dock as GodotAIDock).set_agent_store(_agent_store)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	if _SURFACE_SCENE and _dock is GodotAIDock:
		# Defer so editor main screen is fully ready and our panel gets correct layout.
		call_deferred("_add_main_screen_surface")
	_register_add_to_context_menus()
	# Test-only menu item removed for production plugin.


func _register_add_to_context_menus() -> void:
	if not _dock is GodotAIDock:
		return
	var ei: EditorInterface = get_editor_interface()
	var dock_godot: GodotAIDock = _dock as GodotAIDock
	var slots := [
		EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE,
		EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM,
		EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE,
		EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR,
	]
	for slot in slots:
		var plugin := GodotAIAddToContextMenuPlugin.new(slot, dock_godot, ei)
		add_context_menu_plugin(slot, plugin)
		_context_menu_plugins.append(plugin)


func _add_main_screen_surface() -> void:
	if not _SURFACE_SCENE or not _dock is GodotAIDock:
		return
	var main_screen: Control = get_editor_interface().get_editor_main_screen()
	if not main_screen:
		push_error("Godot AI Assistant: get_editor_main_screen() returned null.")
		return
	_main_screen_panel = (_SURFACE_SCENE as PackedScene).instantiate() as Control
	if not _main_screen_panel:
		push_error("Godot AI Assistant: Failed to instantiate ai_surface.tscn for main screen.")
		_add_main_screen_fallback_panel(main_screen)
		return
	main_screen.add_child(_main_screen_panel)
	if _main_screen_panel is GodotAISurface:
		(_main_screen_panel as GodotAISurface).layout_variant = GodotAISurface.LayoutVariant.MAIN_SCREEN
	if _main_screen_panel is GodotAIDock:
		(_main_screen_panel as GodotAIDock).set_editor_interface(get_editor_interface())
		(_main_screen_panel as GodotAIDock).set_agent_store(_agent_store)
	_make_visible(false)


func _add_main_screen_fallback_panel(main_screen: Control) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.set_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = "Godot AI Assistant\n\nMain screen UI failed to load. Check Output for errors (ui/ai_surface.gd / .tscn)."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(label)
	main_screen.add_child(panel)
	_main_screen_panel = panel


func _add_fallback_dock() -> void:
	var panel := PanelContainer.new()
	var label := Label.new()
	label.text = "Godot AI Assistant failed to load.\nCheck Output/Debugger for errors (e.g. ai_dock.gd or ui/ai_surface.tscn)."
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(label)
	_dock = panel
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	for plugin in _context_menu_plugins:
		if plugin is EditorContextMenuPlugin:
			remove_context_menu_plugin(plugin)
	_context_menu_plugins.clear()
	if _main_screen_panel:
		_main_screen_panel.queue_free()
		_main_screen_panel = null
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _main_screen_panel:
		_main_screen_panel.visible = visible
		if visible:
			_main_screen_panel.queue_sort()
			var parent: Control = _main_screen_panel.get_parent_control()
			if parent:
				parent.queue_sort()


func _get_plugin_name() -> String:
	return "Agent Manager"


func _get_plugin_icon() -> Texture2D:
	var base := get_editor_interface().get_base_control()
	if base:
		# Prefer an icon that suggests AI/agent; fallback to Script.
		var icon := base.get_theme_icon("Script", "EditorIcons")
		if icon:
			return icon
	return null


 
