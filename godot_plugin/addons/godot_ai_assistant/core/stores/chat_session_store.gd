@tool
extends RefCounted
class_name GodotAIChatSessionStore

## Holds session/UI state that should not live on the view.
## Keep this store UI-framework-agnostic (no Control/Node references).

signal activity_changed
signal scrolling_flags_changed

var current_activity: Dictionary = {} # { "text": String, "started_at": float }
var activity_history: Array = []
# [ { "text": String, "started_at": float, "ended_at": float }, ... ]

# Scroll-follow flags (chat streaming UX)
var user_scrolled_away: bool = false
var scroll_was_programmatic: bool = false


func set_activity(current: Dictionary, history: Array) -> void:
	current_activity = current
	activity_history = history
	activity_changed.emit()


func set_current_activity(d: Dictionary) -> void:
	current_activity = d
	activity_changed.emit()


func set_activity_history(a: Array) -> void:
	activity_history = a
	activity_changed.emit()


func set_scroll_flags(p_user_scrolled_away: bool, p_scroll_was_programmatic: bool) -> void:
	user_scrolled_away = p_user_scrolled_away
	scroll_was_programmatic = p_scroll_was_programmatic
	scrolling_flags_changed.emit()

