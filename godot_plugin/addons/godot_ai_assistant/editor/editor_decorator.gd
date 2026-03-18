@tool
extends RefCounted
class_name GodotAIEditorDecorator

## Applies AI edit indicators ([+][~][-][!]) to the editor UI only: script tabs,
## FileSystem tree, Scene tree. Reads status and markers from GodotAIEditStore;
## does not persist or mutate edit state. All edit data lives in ai_edit_store.gd.

var _editor_interface: EditorInterface = null
var _edit_store: GodotAIEditStore = null

## When true, apply_decorations() prints a short diagnostic.
var debug_diagnostic: bool = false

## When true, force the first item in script tabs, FileSystem tree, and Scene tree to show [+]
## so you can verify the decorator is finding and updating those controls.
const DEBUG_FORCE_FIRST_GREEN := true


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
	var msg := (
		"GodotAIEditorDecorator: script_editor=%s tab_bar=%s fs_tree=%s scene_tree=%s file_status_size=%d"
	)
	print(msg % [
		"found" if script_editor else "not found",
		"found" if tab_bar else "not found",
		"found" if fs_tree else "not found",
		"found" if scene_tree else "not found",
		n
	])


## Godot 4.x: ScriptEditor may use TabContainer; get TabBar that shows script tabs (match open_scripts count).
func _find_script_editor_tab_bar(script_editor: Object) -> TabBar:
	if script_editor == null:
		return null
	var node := script_editor as Node
	if node == null:
		return null
	var open_count: int = script_editor.get_open_scripts().size() if script_editor.has_method("get_open_scripts") else 0
	var candidates: Array = []
	_collect_tab_bars(node, candidates)
	# Prefer the TabBar whose tab count matches open scripts (the script list tabs)
	for tb in candidates:
		if tb is TabBar:
			var bar: TabBar = tb as TabBar
			if bar.tab_count > 0 and (open_count <= 0 or bar.tab_count == open_count):
				return bar
	# Fallback: first TabBar with any tabs
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
		var raw := GodotAIEditStore.strip_markers(title)
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
	if DEBUG_FORCE_FIRST_GREEN and tab_bar.tab_count > 0:
		var raw_first := GodotAIEditStore.strip_markers(tab_bar.get_tab_title(0))
		tab_bar.set_tab_title(0, GodotAIEditStore.FILE_MARKER_CREATED + raw_first)


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
	# Engine exposes get_tree_control() on FileSystemDock in some versions
	if fsdock.has_method("get_tree_control"):
		var t = fsdock.get_tree_control()
		if t is Tree:
			return t as Tree
	var node := fsdock as Node
	if node == null:
		return null
	# Engine uses FileSystemTree (class name); node name may be "Tree" or "FileSystemTree"
	var tree_node = node.find_child("Tree", true, false)
	if tree_node is Tree:
		return tree_node as Tree
	tree_node = node.find_child("FileSystemTree", true, false)
	if tree_node is Tree:
		return tree_node as Tree
	# Fallback: first Tree descendant (by type)
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
	if DEBUG_FORCE_FIRST_GREEN:
		var first := root.get_first_child() if root.get_first_child() else root
		var raw := GodotAIEditStore.strip_markers(first.get_text(0))
		first.set_text(0, GodotAIEditStore.FILE_MARKER_CREATED + raw)


func _get_item_path_from_metadata(md: Variant) -> String:
	if typeof(md) == TYPE_STRING:
		return GodotAIEditStore.normalize_for_display_match(str(md))
	if typeof(md) == TYPE_DICTIONARY:
		var d: Dictionary = md
		var p = d.get("path", d.get("file_path", ""))
		if typeof(p) == TYPE_STRING and not str(p).is_empty():
			return GodotAIEditStore.normalize_for_display_match(str(p))
	return ""


func _decorate_tree_items_files(item: TreeItem) -> void:
	while item:
		var text := item.get_text(0)
		var raw := GodotAIEditStore.strip_markers(text)
		var md := item.get_metadata(0)
		var path_to_check := _get_item_path_from_metadata(md)
		var marker := ""
		if not path_to_check.is_empty():
			marker = _edit_store.get_file_marker(path_to_check)
		if marker.is_empty():
			for fp in _edit_store.file_status.keys():
				var n := GodotAIEditStore.normalize_for_display_match(fp)
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


## SceneTreeDock contains SceneTreeEditor (a Control), which contains the actual Tree. Get that Tree.
func _find_scene_tree(base: Control) -> Tree:
	if base == null:
		return null
	var scenedock: Node = base.find_child("SceneTreeDock", true, false) as Node
	if scenedock == null:
		scenedock = base.find_child("Scene", true, false) as Node
	if scenedock != null:
		var editor = scenedock.find_child("SceneTreeEditor", true, false)
		if editor != null:
			var tree := _tree_from_scene_tree_editor(editor)
			if tree != null:
				return tree
		# Fallback: any Tree under dock
		var t := _find_tree_under(scenedock)
		if t != null:
			return t
	var main_screen := _editor_interface.get_editor_main_screen()
	if main_screen is Node:
		var editor = (main_screen as Node).find_child("SceneTreeEditor", true, false)
		if editor != null:
			var tree := _tree_from_scene_tree_editor(editor)
			if tree != null:
				return tree
		var first_tree := _find_tree_under(main_screen as Node)
		if first_tree != null:
			return first_tree
	return null


func _tree_from_scene_tree_editor(editor: Node) -> Tree:
	# SceneTreeEditor is a Control that contains a Tree; engine has get_scene_tree()
	if editor.has_method("get_scene_tree"):
		var t = editor.get_scene_tree()
		if t is Tree:
			return t as Tree
	return editor.find_child("Tree", true, false) as Tree


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
	if DEBUG_FORCE_FIRST_GREEN:
		var raw := GodotAIEditStore.strip_markers(root.get_text(0))
		root.set_text(0, GodotAIEditStore.NODE_MARKER_CREATED + raw)


func _decorate_tree_items_nodes(item: TreeItem, scene_path: String, parent_path: String) -> void:
	while item:
		var text := item.get_text(0)
		var raw := GodotAIEditStore.strip_markers(text)
		var my_path := raw if parent_path.is_empty() else parent_path + "/" + raw
		var marker := _edit_store.get_node_marker(scene_path, my_path)
		item.set_text(0, marker + raw)
		if item.get_first_child():
			_decorate_tree_items_nodes(item.get_first_child(), scene_path, my_path)
		item = item.get_next()
