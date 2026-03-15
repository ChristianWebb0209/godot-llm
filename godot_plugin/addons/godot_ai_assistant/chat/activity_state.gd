@tool
extends RefCounted
class_name GodotAIActivityState

## Activity state: push/clear activity, format elapsed, update UI, glow tween.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


static func format_elapsed(sec: float) -> String:
	if sec < 1.0:
		return "%.1fs" % sec
	elif sec < 60.0:
		return "%.0fs" % sec
	else:
		return "%dm %.0fs" % [int(sec / 60.0), fmod(sec, 60.0)]


func save_current_chat_activity() -> void:
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		var c: Dictionary = _dock.get_chats()[_dock.get_current_chat()]
		c["current_activity"] = _dock.get_current_activity().duplicate()
		c["activity_history"] = _dock.get_activity_history().duplicate()


func push_activity(line: String) -> void:
	if line.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _dock.get_current_activity().size() > 0:
		_dock.get_activity_history().append({
			"text": _dock.get_current_activity()["text"],
			"started_at": _dock.get_current_activity()["started_at"],
			"ended_at": now,
		})
	_dock.set_current_activity_dict({"text": line, "started_at": now})
	save_current_chat_activity()
	stop_activity_glow()
	update_activity_ui()
	start_activity_glow()
	_dock.render_chat_log()


func clear_activity() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _dock.get_current_activity().size() > 0:
		_dock.get_activity_history().append({
			"text": _dock.get_current_activity()["text"],
			"started_at": _dock.get_current_activity()["started_at"],
			"ended_at": now,
		})
	_dock.set_current_activity_dict({})
	save_current_chat_activity()
	stop_activity_glow()
	update_activity_ui()
	_dock.render_chat_log()


func update_activity_ui() -> void:
	if _dock.current_activity_label:
		if _dock.get_current_activity().size() > 0:
			_dock.current_activity_label.text = _dock.get_current_activity()["text"]
			_dock.current_activity_label.visible = true
		else:
			_dock.current_activity_label.text = ""
			_dock.current_activity_label.visible = false
	if _dock.thought_history_button:
		if _dock.chat_message_list != null:
			_dock.thought_history_button.visible = false
		else:
			var n := _dock.get_activity_history().size()
			_dock.thought_history_button.visible = n > 0
			var suffix := " ▼" if _dock.thought_history_list.visible else " ▶"
			_dock.thought_history_button.text = "Thought history (%d)" % n + suffix
	if _dock.thought_history_list:
		for c in _dock.thought_history_list.get_children():
			c.queue_free()
		for i in range(_dock.get_activity_history().size() - 1, -1, -1):
			var h: Dictionary = _dock.get_activity_history()[i]
			var elapsed: float = float(h.get("ended_at", 0) - h.get("started_at", 0))
			var elapsed_str := format_elapsed(elapsed)
			var l := Label.new()
			l.text = "  %s   %s" % [str(h.get("text", "")), elapsed_str]
			l.add_theme_font_size_override("font_size", 12)
			l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
			_dock.thought_history_list.add_child(l)


func start_activity_glow() -> void:
	if not _dock.current_activity_label or _dock.get_current_activity().is_empty():
		return
	stop_activity_glow()
	var t := _dock.create_tween()
	t.set_loops()
	t.tween_property(_dock.current_activity_label, "modulate:a", 0.65, 0.45)
	t.tween_property(_dock.current_activity_label, "modulate:a", 1.0, 0.45)
	_dock.set_activity_glow_tween_ref(t)


func stop_activity_glow() -> void:
	var tw := _dock.get_activity_glow_tween()
	if tw:
		tw.kill()
		_dock.set_activity_glow_tween_ref(null)
	if _dock.current_activity_label:
		_dock.current_activity_label.modulate.a = 1.0
