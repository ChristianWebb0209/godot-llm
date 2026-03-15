@tool
extends RefCounted
class_name GodotAIFS

## Filesystem operations: list_directory, list_files, search_files.

static func execute_list_directory(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = output.get("path", "res://")
	var recursive: bool = output.get("recursive", false)
	var max_entries: int = int(output.get("max_entries", 250))
	var max_depth: int = int(output.get("max_depth", 6))
	if path.is_empty():
		path = "res://"
	if max_entries < 1:
		max_entries = 1
	if max_entries > 2000:
		max_entries = 2000
	if max_depth < 0:
		max_depth = 0
	if max_depth > 20:
		max_depth = 20
	var results: Array = []
	var root_abs := executor.project_path_to_absolute(path)
	var stack: Array = [{"abs": root_abs, "res": path, "depth": 0}]
	while not stack.is_empty() and results.size() < max_entries:
		var cur: Dictionary = stack.pop_back()
		var dir_abs: String = str(cur.get("abs", ""))
		var dir_res: String = str(cur.get("res", ""))
		var depth: int = int(cur.get("depth", 0))
		var da := DirAccess.open(dir_abs)
		if da == null:
			continue
		da.list_dir_begin()
		while results.size() < max_entries:
			var name := da.get_next()
			if name.is_empty():
				break
			if name == "." or name == "..":
				continue
			var child_abs := dir_abs.path_join(name)
			var child_res := dir_res.trim_suffix("/").path_join(name)
			var is_dir := da.current_is_dir()
			results.append({"path": child_res, "is_dir": is_dir})
			if recursive and is_dir and depth < max_depth:
				stack.append({"abs": child_abs, "res": child_res, "depth": depth + 1})
		da.list_dir_end()
	return {
		"success": true,
		"message": "Listed %d entries under %s" % [results.size(), path],
		"path": path,
		"entries": results,
	}


static func execute_search_files(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var query: String = str(output.get("query", ""))
	var root_path: String = str(output.get("root_path", "res://"))
	var extensions := output.get("extensions", [])
	var max_matches: int = int(output.get("max_matches", 50))
	if query.strip_edges().is_empty():
		return {"success": false, "message": "query is required"}
	if root_path.is_empty():
		root_path = "res://"
	if max_matches < 1:
		max_matches = 1
	if max_matches > 500:
		max_matches = 500

	var exts: Array[String] = []
	if extensions is Array:
		for e in extensions:
			var s := str(e).strip_edges()
			if s.is_empty():
				continue
			if not s.begins_with("."):
				s = "." + s
			exts.append(s.to_lower())

	var matches: Array = []
	var root_abs := executor.project_path_to_absolute(root_path)
	var stack: Array = [{"abs": root_abs, "res": root_path, "depth": 0}]
	while not stack.is_empty() and matches.size() < max_matches:
		var cur: Dictionary = stack.pop_back()
		var dir_abs: String = str(cur.get("abs", ""))
		var dir_res: String = str(cur.get("res", ""))
		var depth: int = int(cur.get("depth", 0))
		var da := DirAccess.open(dir_abs)
		if da == null:
			continue
		da.list_dir_begin()
		while matches.size() < max_matches:
			var name := da.get_next()
			if name.is_empty():
				break
			if name == "." or name == "..":
				continue
			var child_abs := dir_abs.path_join(name)
			var child_res := dir_res.trim_suffix("/").path_join(name)
			if da.current_is_dir():
				if depth < 50:
					stack.append({"abs": child_abs, "res": child_res, "depth": depth + 1})
				continue
			if exts.size() > 0:
				var ext := ("." + child_res.get_extension()).to_lower()
				if not exts.has(ext):
					continue
			var txt: String = GodotAIFile.read_text_file_abs(child_abs)
			if txt.is_empty():
				continue
			if txt.find(query) == -1:
				continue
			var previews: Array[String] = []
			var lines: PackedStringArray = txt.split("\n")
			for i in range(lines.size()):
				if query in lines[i]:
					previews.append("%d:%s" % [i + 1, lines[i].strip_edges()])
					if previews.size() >= 3:
						break
			matches.append({"path": child_res, "previews": previews})
		da.list_dir_end()
	return {
		"success": true,
		"message": "Found %d matches for '%s' under %s" % [matches.size(), query, root_path],
		"query": query,
		"root_path": root_path,
		"matches": matches,
	}


static func execute_list_files(executor: GodotAIEditorToolExecutor, output: Dictionary) -> Dictionary:
	var path: String = str(output.get("path", "res://"))
	var recursive: bool = output.get("recursive", true)
	var extensions := output.get("extensions", [])
	var max_entries: int = int(output.get("max_entries", 500))
	if path.is_empty():
		path = "res://"
	if max_entries < 1:
		max_entries = 1
	if max_entries > 2000:
		max_entries = 2000
	var exts: Array[String] = []
	if extensions is Array:
		for e in extensions:
			var s := str(e).strip_edges()
			if s.is_empty():
				continue
			if not s.begins_with("."):
				s = "." + s
			exts.append(s.to_lower())
	var paths: Array = []
	var root_abs := executor.project_path_to_absolute(path)
	var stack: Array = [{"abs": root_abs, "res": path, "depth": 0}]
	while not stack.is_empty() and paths.size() < max_entries:
		var cur: Dictionary = stack.pop_back()
		var dir_abs: String = str(cur.get("abs", ""))
		var dir_res: String = str(cur.get("res", ""))
		var depth: int = int(cur.get("depth", 0))
		var da := DirAccess.open(dir_abs)
		if da == null:
			continue
		da.list_dir_begin()
		while paths.size() < max_entries:
			var name := da.get_next()
			if name.is_empty():
				break
			if name == "." or name == "..":
				continue
			var child_abs := dir_abs.path_join(name)
			var child_res := dir_res.trim_suffix("/").path_join(name)
			if da.current_is_dir():
				if recursive and depth < 50:
					stack.append({"abs": child_abs, "res": child_res, "depth": depth + 1})
				continue
			if exts.size() > 0:
				var ext := ("." + child_res.get_extension()).to_lower()
				if not exts.has(ext):
					continue
			paths.append(child_res)
		da.list_dir_end()
	return {
		"success": true,
		"message": "Listed %d file(s) under %s" % [paths.size(), path],
		"path": path,
		"paths": paths,
	}
