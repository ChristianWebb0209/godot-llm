@tool
extends TextEdit
class_name GodotAIPromptInput

## TextEdit for chat prompt; accepts editor drag-and-drop (FileSystem, Scene tree, Script list).
## Dropped files/nodes are added as pinned context for the chat.

func _get_dock() -> GodotAIDock:
	var n: Node = self
	for _iter in range(6):
		n = n.get_parent()
		if n is GodotAIDock:
			return n as GodotAIDock
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data == null:
		return false
	# Script editor selection: plain text (drag from CodeEdit)
	if data is String:
		return (data as String).strip_edges().length() > 0
	if data is Dictionary:
		var d: Dictionary = data
		# Selection text from right-click or custom drag
		if str(d.get("selection_text", d.get("text", ""))).strip_edges().length() > 0:
			return true
		if d.has("files"):
			var files: Variant = d["files"]
			if files is PackedStringArray and (files as PackedStringArray).size() > 0:
				return true
			if files is Array and (files as Array).size() > 0:
				return true
		if d.has("nodes"):
			var nodes: Variant = d["nodes"]
			if nodes is Array and (nodes as Array).size() > 0:
				return true
		if d.has("resource_path") and str(d.get("resource_path", "")).strip_edges().length() > 0:
			return true
		if d.has("script") and d["script"] != null:
			return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var dock: GodotAIDock = _get_dock()
	if dock == null:
		return
	dock.add_pinned_context_from_drag_data(data)
