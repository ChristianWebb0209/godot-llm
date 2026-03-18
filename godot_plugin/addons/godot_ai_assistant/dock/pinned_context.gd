@tool
extends RefCounted
class_name GodotAIPinnedContext

## Controller: per-chat pinned context (drag/drop → pinned_context entries + UI refresh).

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func add_from_drag_data(data: Variant) -> void:
	_dock.ensure_chat_has_messages_internal()
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return
	var chat: Dictionary = _dock.get_chats()[_dock.get_current_chat()]
	if not chat.has("pinned_context"):
		chat["pinned_context"] = []
	var pinned: Array = chat["pinned_context"]

	# Script selection: plain string or dict with selection_text/text
	if data is String:
		var text: String = (data as String).strip_edges()
		if not text.is_empty():
			var entry: Dictionary = {"type": "selection", "text": text, "source_path": ""}
			pinned.append(entry)
			refresh_row()
			_dock.set_status("Added to context for this chat.")
		return
	if data is Dictionary:
		var d: Dictionary = data
		var sel_text: String = str(d.get("selection_text", d.get("text", ""))).strip_edges()
		if not sel_text.is_empty():
			var src: String = str(d.get("source_path", "")).strip_edges()
			var entry: Dictionary = {"type": "selection", "text": sel_text, "source_path": src}
			pinned.append(entry)
			refresh_row()
			_dock.set_status("Added to context for this chat.")
			return
		# Fall through to handle files/nodes/resource_path/script in same dict
	else:
		return
	var d: Dictionary = data

	# FileSystem dock: data["files"] = PackedStringArray or Array of paths
	if d.has("files"):
		var files: Variant = d["files"]
		var paths: Array = []
		if files is PackedStringArray:
			for i in (files as PackedStringArray).size():
				paths.append((files as PackedStringArray)[i])
		elif files is Array:
			paths = (files as Array).duplicate()
		for path in paths:
			var p: String = str(path).strip_edges()
			if p.is_empty():
				continue
			if not p.begins_with("res://"):
				p = "res://" + p
			var entry: Dictionary = {"type": "file", "path": p}
			if contains_entry(pinned, entry):
				continue
			pinned.append(entry)

	# Scene tree: data["nodes"] (array of NodePath or dicts), optional data["scene"] / "from_scene"
	elif d.has("nodes"):
		var nodes_raw: Variant = d["nodes"]
		var scene_path: String = str(d.get("scene", d.get("from_scene", ""))).strip_edges()
		if scene_path.is_empty() and _dock.get_editor_interface_ref():
			var root = _dock.get_editor_interface_ref().get_edited_scene_root()
			if root:
				scene_path = root.scene_file_path
		var ei := _dock.get_editor_interface_ref()
		var root_node = ei.get_edited_scene_root() if ei else null
		var root_name: String = root_node.name if root_node else ""
		var node_list: Array = nodes_raw if nodes_raw is Array else []
		for n in node_list:
			var node_path_str: String = ""
			var node_name_str: String = ""
			if n is NodePath:
				node_path_str = str(n)
				var np := n as NodePath
				node_name_str = np.get_name(np.get_name_count() - 1)
			elif n is Dictionary:
				var nd := n as Dictionary
				node_path_str = str(nd.get("path", nd.get("node_path", "")))
				node_name_str = str(nd.get("name", nd.get("node_name", "")))
			else:
				node_path_str = str(n)
			if node_path_str.is_empty():
				continue
			if node_name_str.is_empty():
				node_name_str = node_path_str.get_file()
			# Treat scene root as a special entry
			var is_scene_root: bool = (
				node_path_str == "." or node_path_str == "/"
				or (root_name and (node_name_str == root_name or node_path_str == root_name))
			)
			var entry: Dictionary
			if is_scene_root and not scene_path.is_empty():
				entry = {
					"type": "scene_root",
					"scene_path": scene_path,
					"node_name": root_name if root_name else "Root"
				}
			else:
				entry = {
					"type": "node",
					"node_path": node_path_str,
					"node_name": node_name_str,
					"scene_path": scene_path
				}
			if contains_entry(pinned, entry):
				continue
			pinned.append(entry)

	# Single resource/script (e.g. script tab drag)
	elif d.has("resource_path"):
		var p: String = str(d.get("resource_path", "")).strip_edges()
		if not p.is_empty():
			if not p.begins_with("res://"):
				p = "res://" + p
			var entry: Dictionary = {"type": "file", "path": p}
			if not contains_entry(pinned, entry):
				pinned.append(entry)
	elif d.has("script") and d["script"] != null:
		var scr: Script = d["script"] as Script
		if scr and scr.resource_path:
			var p: String = scr.resource_path
			var entry: Dictionary = {"type": "file", "path": p}
			if not contains_entry(pinned, entry):
				pinned.append(entry)

	refresh_row()
	_dock.set_status("Added to context for this chat.")


func contains_entry(pinned: Array, entry: Dictionary) -> bool:
	var path_a: String = str(entry.get("path", "")).strip_edges()
	var node_path_a: String = str(entry.get("node_path", "")).strip_edges()
	var scene_path_a: String = str(entry.get("scene_path", "")).strip_edges()
	for e in pinned:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if d.get("type") == "file" and path_a and str(d.get("path", "")).strip_edges() == path_a:
			return true
		if d.get("type") == "node" and node_path_a and str(d.get("node_path", "")).strip_edges() == node_path_a:
			return true
		if d.get("type") == "scene_root" and scene_path_a and str(d.get("scene_path", "")).strip_edges() == scene_path_a:
			return true
	return false


func get_current() -> Array:
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return []
	var chat: Dictionary = _dock.get_chats()[_dock.get_current_chat()]
	var ctx: Array = chat.get("pinned_context", [])
	return ctx.duplicate()


func remove_entry(chat_index: int, entry_index: int) -> void:
	if chat_index < 0 or chat_index >= _dock.get_chats().size():
		return
	var chat: Dictionary = _dock.get_chats()[chat_index]
	if not chat.has("pinned_context"):
		return
	var pinned: Array = chat["pinned_context"]
	if entry_index < 0 or entry_index >= pinned.size():
		return
	pinned.remove_at(entry_index)
	refresh_row()


func build_extra() -> Dictionary:
	var out: Dictionary = {}
	var pinned: Array = get_current()
	if pinned.is_empty():
		return out
	var files_arr: Array = []
	var nodes_arr: Array = []
	var selections_arr: Array = []
	for e in pinned:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if d.get("type") == "file":
			var path: String = str(d.get("path", "")).strip_edges()
			if path.is_empty():
				continue
			var content: String = GodotAIContextPayload.read_file_res(path) if path else ""
			files_arr.append({"path": path, "content": content})
		elif d.get("type") == "scene_root":
			var scene_path: String = str(d.get("scene_path", "")).strip_edges()
			var node_name: String = str(d.get("node_name", "")).strip_edges()
			var scene_file: String = scene_path.get_file() if scene_path else "scene"
			var desc: String = "Scene root (%s)" % scene_file
			var ei := _dock.get_editor_interface_ref()
			if ei and scene_path:
				var root = ei.get_edited_scene_root()
				if root and root.scene_file_path == scene_path:
					desc = "Scene root: %s (%s) - %s" % [root.name, root.get_class(), scene_file]
			nodes_arr.append({
				"scene_path": scene_path,
				"node_path": ".",
				"node_name": node_name,
				"description": desc,
				"is_scene_root": true
			})
		elif d.get("type") == "node":
			var node_path_str: String = str(d.get("node_path", "")).strip_edges()
			var node_name: String = str(d.get("node_name", "")).strip_edges()
			var scene_path: String = str(d.get("scene_path", "")).strip_edges()
			var desc: String = "Node: %s (path: %s)" % [node_name, node_path_str]
			var ei := _dock.get_editor_interface_ref()
			if ei and scene_path:
				var root = ei.get_edited_scene_root()
				if root and root.scene_file_path == scene_path:
					var n: Node = root.get_node_or_null(node_path_str)
					if n:
						desc = "Node: %s (%s) path=%s" % [n.name, n.get_class(), node_path_str]
			nodes_arr.append({
				"scene_path": scene_path,
				"node_path": node_path_str,
				"node_name": node_name,
				"description": desc
			})
		elif d.get("type") == "selection":
			var text: String = str(d.get("text", "")).strip_edges()
			var src: String = str(d.get("source_path", "")).strip_edges()
			if not text.is_empty():
				selections_arr.append({"text": text, "source_path": src})
	if files_arr.size() > 0:
		out["pinned_files"] = files_arr
	if nodes_arr.size() > 0:
		out["pinned_nodes"] = nodes_arr
	if selections_arr.size() > 0:
		out["pinned_selections"] = selections_arr
	if files_arr.size() > 0 or nodes_arr.size() > 0 or selections_arr.size() > 0:
		out["pinned_context_note"] = (
			"The user just dragged these items into context for this chat. "
			+ "Prioritize them when answering."
		)
	return out


func refresh_row() -> void:
	var row: HBoxContainer = _dock.pinned_context_row
	if not row:
		return
	for c in row.get_children():
		c.queue_free()
	var pinned: Array = get_current()
	row.visible = not pinned.is_empty()
	if pinned.is_empty():
		return
	var chat_idx: int = _dock.get_current_chat()
	for i in range(pinned.size()):
		var e: Variant = pinned[i]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var label_text: String = ""
		if d.get("type") == "file":
			label_text = (str(d.get("path", "")).strip_edges() as String).get_file()
		elif d.get("type") == "scene_root":
			var sp: String = str(d.get("scene_path", "")).strip_edges()
			label_text = "Scene root (%s)" % (sp.get_file() if sp else "?")
		elif d.get("type") == "selection":
			var t: String = str(d.get("text", "")).strip_edges()
			label_text = "Selection" if t.length() <= 12 else (t.substr(0, 11) + "…")
		else:
			label_text = "Node: " + str(d.get("node_name", "?")).strip_edges()
		var chip_tooltip: String = "Dragged into context. Click x to remove."
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 4)
		var lbl := Label.new()
		lbl.text = label_text
		lbl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		lbl.custom_minimum_size.x = 1
		chip.add_child(lbl)
		var rm := Button.new()
		rm.flat = true
		rm.text = "x"
		rm.tooltip_text = "Remove from context"
		lbl.tooltip_text = chip_tooltip
		var idx := i
		rm.pressed.connect(remove_entry.bind(chat_idx, idx))
		chip.add_child(rm)
		row.add_child(chip)

