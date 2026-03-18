@tool
extends RefCounted
class_name GodotAIEditorChrome

## Controller: editor-only chrome (TabBar theming + periodic decoration refresh).

var _dock: GodotAIDock
var _decoration_timer: Timer = null

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func apply_chat_tab_bar_editor_style() -> void:
	if not _dock.chat_tab_bar or not _dock.get_editor_interface_ref():
		return
	var base: Control = _dock.get_editor_interface_ref().get_base_control()
	if not base or not base.theme:
		return
	_dock.chat_tab_bar.theme = base.theme
	var panel: PanelContainer = _dock.chat_tab_bar.get_parent() as PanelContainer
	if panel:
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.16, 0.16, 0.18, 1)
		bg.set_content_margin_all(4)
		panel.add_theme_stylebox_override("panel", bg)
	var sb_selected := StyleBoxFlat.new()
	sb_selected.bg_color = Color(0.2, 0.2, 0.22, 1)
	sb_selected.set_content_margin_all(4)
	var sb_unselected := StyleBoxFlat.new()
	sb_unselected.bg_color = Color(0.16, 0.16, 0.18, 1)
	sb_unselected.set_content_margin_all(4)
	_dock.chat_tab_bar.add_theme_stylebox_override("tab_selected", sb_selected)
	_dock.chat_tab_bar.add_theme_stylebox_override("tab_unselected", sb_unselected)
	var text_color: Color = base.theme.get_color("font_unselected_color", "TabBar")
	_dock.chat_tab_bar.add_theme_color_override("font_unselected_color", text_color)
	_dock.chat_tab_bar.add_theme_color_override("font_selected_color", text_color)
	if base.theme.has_theme_color("close_icon_color", "TabBar"):
		_dock.chat_tab_bar.add_theme_color_override("close_icon_color", text_color)


func start_decoration_refresh() -> void:
	if _decoration_timer != null and is_instance_valid(_decoration_timer):
		return
	_decoration_timer = Timer.new()
	_decoration_timer.wait_time = 1.0
	_decoration_timer.one_shot = true
	_dock.add_child(_decoration_timer)
	_decoration_timer.timeout.connect(_on_decoration_timer_timeout)
	_decoration_timer.start()


func _on_decoration_timer_timeout() -> void:
	if _dock.get_edit_store() == null:
		_reschedule_decoration_timer()
		return
	var store := _dock.get_edit_store()
	var store_empty := store.file_status.is_empty() and store.node_status.is_empty()
	if store_empty and not GodotAIEditorDecorator.DEBUG_FORCE_FIRST_GREEN:
		_reschedule_decoration_timer()
		return
	_dock._decorator.apply_decorations()
	_reschedule_decoration_timer()


func _reschedule_decoration_timer() -> void:
	if _decoration_timer != null and is_instance_valid(_decoration_timer):
		_decoration_timer.start(1.0)

