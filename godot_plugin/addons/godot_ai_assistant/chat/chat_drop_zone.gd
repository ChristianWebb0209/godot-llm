@tool
extends ScrollContainer
class_name GodotAIChatDropZone

## ScrollContainer that accepts editor drag-and-drop (files, scene nodes) and adds them as pinned context.
## Attach to the chat message scroll so dropping on the message list also works.

func _get_dock() -> GodotAIDock:
	var n: Node = self
	for _iter in range(8):
		n = n.get_parent()
		if n is GodotAIDock:
			return n as GodotAIDock
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data == null or not data is Dictionary:
		return false
	var d: Dictionary = data
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
	var dock := _get_dock()
	if dock != null:
		dock.add_pinned_context_from_drag_data(data)
