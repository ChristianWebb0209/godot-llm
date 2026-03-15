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
	# FileSystem dock: data["files"] = PackedStringArray
	if data is Dictionary:
		var d: Dictionary = data
		if d.has("files"):
			var files: Variant = d["files"]
			if files is PackedStringArray and (files as PackedStringArray).size() > 0:
				return true
			if files is Array and (files as Array).size() > 0:
				return true
		# Scene tree: data["nodes"] (array of NodePath or node dicts)
		if d.has("nodes"):
			var nodes: Variant = d["nodes"]
			if nodes is Array and (nodes as Array).size() > 0:
				return true
		# Single resource/script (e.g. script tab drag)
		if d.has("resource_path") and str(d.get("resource_path", "")).strip_edges().length() > 0:
			return true
		if d.has("script") and d["script"] != null:
			return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var dock := _get_dock()
	if dock == null:
		return
	dock.add_pinned_context_from_drag_data(data)
