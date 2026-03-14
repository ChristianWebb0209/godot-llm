@tool
extends RefCounted
class_name GodotAIEditorDecorator

## Applies AI edit indicators (file/node markers) to the Godot editor UI:
## script tabs, FileSystem tree, and Scene tree. Uses GodotAIEditStore for
## styling constants and status; discovery is robust across Godot 4.x versions.

var _editor_interface: EditorInterface = null
var _edit_store: GodotAIEditStore = null

## When true, apply_decorations() prints a short diagnostic (found/not found, file_status size).
var debug_diagnostic: bool = false


func _init(p_editor_interface: EditorInterface = null, p_edit_store: GodotAIEditStore = null) -> void:
	_editor_interface = p_editor_interface
	_edit_store = p_edit_store


func set_editor_interface(e: EditorInterface) -> void:
	_editor_interface = e


func set_edit_store(store: GodotAIEditStore) -> void:
	_edit_store = store


func apply_decorations() -> void:
	if _editor_interface == null or _edit_store == null:
		if debug_diagnostic:
			print("GodotAIEditorDecorator: editor_interface or edit_store is null")
		return
	var base := _editor_interface.get_base_control()
	if base == null:
		if debug_diagnostic:
			print("GodotAIEditorDecorator: base control is null")
		return
	_decorate_script_tabs()
	_decorate_filesystem_tree()
	_decorate_scene_tree(base)
	if debug_diagnostic:
		_print_diagnostic()


func _print_diagnostic() -> void:
	var script_editor = _editor_interface.get_script_editor() if _editor_interface else null
	var tab_bar := _find_script_editor_tab_bar(script_editor)
	var fsdock = _editor_interface.get_file_system_dock() if _editor_interface else null
	var fs_tree := _find_filesystem_tree(fsdock)
	var base := _editor_interface.get_base_control()
	var scene_tree := _find_scene_tree(base)
	var n := _edit_store.file_status.size() if _edit_store else 0
	print("GodotAIEditorDecorator: script_editor=%s tab_bar=%s fs_tree=%s scene_tree=%s file_status_size=%d" % [
		"found" if script_editor else "not found",
		"found" if tab_bar else "not found",
		"found" if fs_tree else "not found",
		"found" if scene_tree else "not found",
		n
	])


static func _strip_markers(s: String) -> String:
	return GodotAIEditStore.strip_markers(s)


func _normalize_path_for_match(p: String) -> String:
	var s := str(p).replace("\\", "/").strip_edges()
	if s.begins_with("res://"):
		return s
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	if not project_root.is_empty() and s.begins_with(project_root):
		var suffix := s.substr(project_root.length()).replace("\\", "/").strip_edges(true, false)
		return "res://" + suffix.trim_prefix("/")
	return s


## Godot 4.x: ScriptEditor may use TabContainer; get TabBar by name first, then by type.
func _find_script_editor_tab_bar(script_editor: Object) -> TabBar:
	if script_editor == null:
		return null
	var node := script_editor as Node
	if node == null:
		return null
	# By name (engine can rename internally)
	var tab_container: TabContainer = node.find_child("TabContainer", true, false)
	if tab_container is TabContainer and tab_container.get_tab_bar():
		return tab_container.get_tab_bar()
	var tab_bar: TabBar = node.find_child("TabBar", true, false)
	if tab_bar is TabBar:
		return tab_bar
	tab_bar = node.find_child("ScriptEditorTabBar", true, false)
	if tab_bar is TabBar:
		return tab_bar
	# By type: first TabContainer with a tab bar, or first TabBar with tabs (script list)
	var candidates: Array = []
	_collect_tab_bars(node, candidates)
	for tb in candidates:
		if tb is TabBar and (tb as TabBar).tab_count > 0:
			return tb as TabBar
	return null


static func _collect_tab_bars(n: Node, out: Array) -> void:
	if n is TabContainer:
		var bar: TabBar = (n as TabContainer).get_tab_bar()
		if bar != null:
			out.append(bar)
	elif n is TabBar:
		out.append(n)
	for c in n.get_children():
		_collect_tab_bars(c, out)


func _decorate_script_tabs() -> void:
	var script_editor = _editor_interface.get_script_editor() if _editor_interface else null
	if script_editor == null:
		return
	var tab_bar := _find_script_editor_tab_bar(script_editor)
	if tab_bar == null:
		return
	var open_scripts: Array = script_editor.get_open_scripts()
	for i in range(tab_bar.tab_count):
		var title := tab_bar.get_tab_title(i)
		var raw := _strip_markers(title)
		var marker := ""
		if _edit_store and i < open_scripts.size():
			var script_res = open_scripts[i]
			if script_res is Script and script_res.resource_path:
				var path := str((script_res as Script).resource_path)
				marker = _edit_store.get_file_marker(path)
				if marker.is_empty():
					for fp in _edit_store.file_status.keys():
						if str(fp).to_lower().ends_with(raw.to_lower()):
							marker = _edit_store.get_file_marker(str(fp))
							break
		tab_bar.set_tab_title(i, marker + raw)


## Find first Tree under dock; fallback: search by type.
func _find_tree_under(n: Node) -> Tree:
	if n is Tree:
		return n as Tree
	for c in n.get_children():
		var t := _find_tree_under(c)
		if t != null:
			return t
	return null


func _find_filesystem_tree(fsdock: Object) -> Tree:
	if fsdock == null:
		return null
	var node := fsdock as Node
	if node == null:
		return null
	# Prefer named Tree, then any Tree under the dock (Godot 4 layout may nest it)
	var tree_node = node.find_child("Tree", true, false)
	if tree_node is Tree:
		return tree_node as Tree
	return _find_tree_under(node)


func _decorate_filesystem_tree() -> void:
	var fsdock = _editor_interface.get_file_system_dock() if _editor_interface else null
	var tree := _find_filesystem_tree(fsdock)
	if tree == null:
		return
	var root := tree.get_root()
	if root == null:
		return
	_decorate_tree_items_files(root)


func _get_item_path_from_metadata(md: Variant) -> String:
	if typeof(md) == TYPE_STRING:
		return _normalize_path_for_match(str(md))
	if typeof(md) == TYPE_DICTIONARY:
		var d: Dictionary = md
		var p = d.get("path", d.get("file_path", ""))
		if typeof(p) == TYPE_STRING and not str(p).is_empty():
			return _normalize_path_for_match(str(p))
	return ""


func _decorate_tree_items_files(item: TreeItem) -> void:
	while item:
		var text := item.get_text(0)
		var raw := _strip_markers(text)
		var md := item.get_metadata(0)
		var path_to_check := _get_item_path_from_metadata(md)
		var marker := ""
		if not path_to_check.is_empty():
			marker = _edit_store.get_file_marker(path_to_check)
		if marker.is_empty():
			for fp in _edit_store.file_status.keys():
				var n := _normalize_path_for_match(fp)
				if path_to_check.is_empty():
					if n.to_lower().ends_with(raw.to_lower()):
						marker = _edit_store.get_file_marker(str(fp))
						break
				elif n == path_to_check:
					marker = _edit_store.get_file_marker(str(fp))
					break
		item.set_text(0, marker + raw)
		if item.get_first_child():
			_decorate_tree_items_files(item.get_first_child())
		item = item.get_next()


func _find_scene_tree(base: Control) -> Tree:
	if base == null:
		return null
	var scenedock := base.find_child("SceneTreeDock", true, false)
	if scenedock == null:
		scenedock = base.find_child("Scene", true, false)
	if scenedock != null:
		var tree_node = (scenedock as Node).find_child("SceneTreeEditor", true, false)
		if tree_node == null:
			tree_node = (scenedock as Node).find_child("Tree", true, false)
		if tree_node is Tree:
			return tree_node as Tree
		elif tree_node is Node:
			var t := (tree_node as Node).find_child("Tree", true, false)
			if t is Tree:
				return t as Tree
	var main_screen := _editor_interface.get_editor_main_screen()
	if main_screen is Node:
		var tree_node = (main_screen as Node).find_child("SceneTreeEditor", true, false)
		if tree_node is Tree:
			return tree_node as Tree
		elif tree_node is Node:
			var t := (tree_node as Node).find_child("Tree", true, false)
			if t is Tree:
				return t as Tree
		# Fallback: first Tree under main screen (scene tree is usually the only one there)
		var first_tree := _find_tree_under(main_screen as Node)
		if first_tree != null:
			return first_tree
	return null


func _decorate_scene_tree(base: Control) -> void:
	var scene_root := _editor_interface.get_edited_scene_root()
	var scene_path := scene_root.scene_file_path if scene_root else ""
	if scene_path.is_empty():
		return
	var tree := _find_scene_tree(base)
	if tree == null:
		return
	var root := tree.get_root()
	if root == null:
		return
	_decorate_tree_items_nodes(root, scene_path, "")


func _decorate_tree_items_nodes(item: TreeItem, scene_path: String, parent_path: String) -> void:
	while item:
		var text := item.get_text(0)
		var raw := _strip_markers(text)
		var my_path := raw if parent_path.is_empty() else parent_path + "/" + raw
		var marker := _edit_store.get_node_marker(scene_path, my_path)
		item.set_text(0, marker + raw)
		if item.get_first_child():
			_decorate_tree_items_nodes(item.get_first_child(), scene_path, my_path)
		item = item.get_next()
