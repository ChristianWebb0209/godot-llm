from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

from ..rag_core import SourceChunk, _collect_top_docs, _collect_code_results


@dataclass
class ToolDef:
    name: str
    description: str
    # JSON-schema-like parameters shape for OpenAI tools
    parameters: Dict[str, Any]
    # Backend implementation: (args_dict) -> result serializable to JSON
    handler: Callable[[Dict[str, Any]], Any]


def _tool_search_docs(args: Dict[str, Any]) -> Dict[str, Any]:
    query: str = args.get("query", "")
    top_k: int = int(args.get("top_k", 5))
    docs: List[SourceChunk] = _collect_top_docs(query, top_k=top_k)
    return {
        "results": [
            {
                "id": d.id,
                "path": d.source_path,
                "score": d.score,
                "metadata": d.metadata,
                "preview": d.text_preview,
            }
            for d in docs
        ]
    }


def _tool_search_project_code(args: Dict[str, Any]) -> Dict[str, Any]:
    query: str = args.get("query", "")
    language: Optional[str] = args.get("language") or None
    top_k: int = int(args.get("top_k", 5))
    snippets: List[SourceChunk] = _collect_code_results(
        question=query,
        language=language,
        top_k=top_k,
    )
    return {
        "results": [
            {
                "id": s.id,
                "path": s.source_path,
                "score": s.score,
                "metadata": s.metadata,
                "preview": s.text_preview,
            }
            for s in snippets
        ]
    }


# --- Editor tools: executed on the Godot client; backend returns payload only ---

def _editor_payload(name: str, **kwargs: Any) -> Dict[str, Any]:
    """Return a payload that the Godot plugin will execute locally."""
    out: Dict[str, Any] = {"execute_on_client": True, "action": name}
    out.update(kwargs)
    return out


def _tool_create_file(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    content = args.get("content", "")
    overwrite = bool(args.get("overwrite", False))
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("create_file", path=path, content=content, overwrite=overwrite)


def _tool_write_file(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    content = args.get("content", "")
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("write_file", path=path, content=content)


def _tool_apply_patch(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    old_string = args.get("old_string", "")
    new_string = args.get("new_string", "")
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload(
        "apply_patch", path=path, old_string=old_string, new_string=new_string
    )


def _tool_create_script(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    language = (args.get("language") or "gdscript").strip().lower()
    extends_class = (args.get("extends_class") or "Node").strip()
    initial_content = args.get("initial_content", "")
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    if language not in ("gdscript", "csharp"):
        return {"error": "language must be gdscript or csharp", "execute_on_client": False}
    return _editor_payload(
        "create_script",
        path=path,
        language=language,
        extends_class=extends_class,
        initial_content=initial_content,
    )


def _normalize_scene_path(path: str) -> str:
    p = (path or "").strip()
    if not p:
        return p
    if not p.startswith("res://"):
        p = "res://" + p
    return p


def _tool_create_node(args: Dict[str, Any]) -> Dict[str, Any]:
    scene_path = _normalize_scene_path(args.get("scene_path") or "")
    parent_path = (args.get("parent_path") or "/root").strip()
    node_type = (args.get("node_type") or "Node").strip()
    node_name = (args.get("node_name") or "").strip()
    if not scene_path:
        return {"error": "scene_path is required", "execute_on_client": False}
    if not node_type:
        return {"error": "node_type is required", "execute_on_client": False}
    return _editor_payload(
        "create_node",
        scene_path=scene_path,
        parent_path=parent_path,
        node_type=node_type,
        node_name=node_name or None,
    )


def _tool_modify_attribute(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Generic tool to set an attribute/property. Use target_type to choose what to modify:
    - node: a property on a node in a scene (scene_path, node_path, attribute, value).
    - import: a key in the [params] section of a resource's .import file (path, attribute, value).
    """
    target_type = str(args.get("target_type") or "").strip().lower()
    attribute = str(args.get("attribute") or "").strip()
    value = args.get("value")
    if not target_type or not attribute:
        return {
            "error": "target_type and attribute are required",
            "execute_on_client": False,
        }
    if value is None:
        return {"error": "value is required", "execute_on_client": False}
    if target_type == "node":
        scene_path = _normalize_scene_path(args.get("scene_path") or "")
        node_path = (args.get("node_path") or "").strip()
        if not scene_path or not node_path:
            return {
                "error": "For target_type=node, scene_path and node_path are required",
                "execute_on_client": False,
            }
        return _editor_payload(
            "modify_attribute",
            target_type="node",
            scene_path=scene_path,
            node_path=node_path,
            attribute=attribute,
            value=value,
        )
    if target_type == "import":
        path = str(args.get("path") or "").strip()
        if not path:
            return {
                "error": "For target_type=import, path is required (e.g. res://icon.svg)",
                "execute_on_client": False,
            }
        return _editor_payload(
            "modify_attribute",
            target_type="import",
            path=path,
            attribute=attribute,
            value=value,
        )
    return {
        "error": "target_type must be 'node' or 'import'",
        "execute_on_client": False,
    }


def _tool_read_file(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("read_file", path=path)


def _tool_delete_file(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("delete_file", path=path)


def _tool_lint_file(args: Dict[str, Any]) -> Dict[str, Any]:
    """Run the Godot linter on a project file. Executed on the client; result is shown in the editor."""
    path = (args.get("path") or "").strip()
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("lint_file", path=path)


def _tool_list_directory(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "res://").strip() or "res://"
    recursive = bool(args.get("recursive", False))
    max_entries = int(args.get("max_entries", 250))
    max_depth = int(args.get("max_depth", 6))
    if max_entries < 1:
        max_entries = 1
    if max_entries > 2000:
        max_entries = 2000
    if max_depth < 0:
        max_depth = 0
    if max_depth > 20:
        max_depth = 20
    return _editor_payload(
        "list_directory",
        path=path,
        recursive=recursive,
        max_entries=max_entries,
        max_depth=max_depth,
    )


def _tool_search_files(args: Dict[str, Any]) -> Dict[str, Any]:
    query = str(args.get("query") or "").strip()
    root_path = str(args.get("root_path") or "res://").strip() or "res://"
    extensions = args.get("extensions") or []
    max_matches = int(args.get("max_matches", 50))
    if not query:
        return {"error": "query is required", "execute_on_client": False}
    if max_matches < 1:
        max_matches = 1
    if max_matches > 500:
        max_matches = 500
    if not isinstance(extensions, list):
        extensions = []
    return _editor_payload(
        "search_files",
        query=query,
        root_path=root_path,
        extensions=extensions,
        max_matches=max_matches,
    )


def _tool_list_files(args: Dict[str, Any]) -> Dict[str, Any]:
    """List file paths under res:// by optional extension(s), no content search (glob-style)."""
    path = str(args.get("path") or "res://").strip() or "res://"
    recursive = bool(args.get("recursive", True))
    extensions = args.get("extensions") or []
    max_entries = int(args.get("max_entries", 500))
    if max_entries < 1:
        max_entries = 1
    if max_entries > 2000:
        max_entries = 2000
    if not isinstance(extensions, list):
        extensions = []
    return _editor_payload(
        "list_files",
        path=path,
        recursive=recursive,
        extensions=extensions,
        max_entries=max_entries,
    )


def _tool_read_import_options(args: Dict[str, Any]) -> Dict[str, Any]:
    """Read the .import file for a resource (e.g. res://icon.svg). Returns full content or params section."""
    path = str(args.get("path") or "").strip()
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("read_import_options", path=path)




def get_registered_tools() -> List[ToolDef]:
    """
    Return the list of tools available to the LLM.
    This is the single source of truth for backend-side tools for now.
    """
    return [
        ToolDef(
            name="search_docs",
            description="Search the indexed Godot documentation for relevant pages/snippets.",
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural language query or keywords to search in docs.",
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Maximum number of results to return.",
                        "default": 5,
                        "minimum": 1,
                        "maximum": 20,
                    },
                },
                "required": ["query"],
            },
            handler=_tool_search_docs,
        ),
        ToolDef(
            name="search_project_code",
            description=(
                "Search the indexed project_code collection for relevant scripts or shaders. "
                "Use this to locate concrete examples in the current project."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural language description or code keywords.",
                    },
                    "language": {
                        "type": "string",
                        "description": "Optional language filter: 'gdscript', 'csharp', or 'gdshader'.",
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Maximum number of results to return.",
                        "default": 5,
                        "minimum": 1,
                        "maximum": 20,
                    },
                },
                "required": ["query"],
            },
            handler=_tool_search_project_code,
        ),
        # --- Editor tools (executed on Godot client) ---
        ToolDef(
            name="create_file",
            description=(
                "Create a new file in the project. Use a project path like res://scripts/name.gd. "
                "If overwrite is false, the file must not exist."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/foo.gd"},
                    "content": {"type": "string", "description": "Full file content.", "default": ""},
                    "overwrite": {"type": "boolean", "description": "Overwrite if exists.", "default": False},
                },
                "required": ["path"],
            },
            handler=_tool_create_file,
        ),
        ToolDef(
            name="write_file",
            description="Overwrite a file with new content. Creates the file if it does not exist.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/foo.gd"},
                    "content": {"type": "string", "description": "Full file content."},
                },
                "required": ["path", "content"],
            },
            handler=_tool_write_file,
        ),
        ToolDef(
            name="apply_patch",
            description=(
                "Edit a file by replacing the first occurrence of old_string with new_string. "
                "Use for small, targeted edits in scripts or scenes."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path to the file."},
                    "old_string": {"type": "string", "description": "Exact text to find and replace."},
                    "new_string": {"type": "string", "description": "Replacement text."},
                },
                "required": ["path", "old_string", "new_string"],
            },
            handler=_tool_apply_patch,
        ),
        ToolDef(
            name="create_script",
            description=(
                "Create a new GDScript or C# script file with an optional extends line and initial content."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/player.gd"},
                    "language": {"type": "string", "description": "gdscript or csharp", "default": "gdscript"},
                    "extends_class": {"type": "string", "description": "Base class, e.g. Node, CharacterBody2D", "default": "Node"},
                    "initial_content": {"type": "string", "description": "Optional body content.", "default": ""},
                },
                "required": ["path"],
            },
            handler=_tool_create_script,
        ),
        ToolDef(
            name="create_node",
            description=(
                "Add a new node to a scene. Executes in the Godot editor: opens the scene, adds the node, saves. "
                "node_type MUST be a built-in Godot class (Node, Node2D, Node3D, Control, Button, Label, "
                "CharacterBody2D, Sprite2D, etc.). Do NOT use 'Component'—Godot has no Component class; use Node "
                "or Node2D and attach a script via create_script if you need custom behavior. "
                "scene_path: res:// path to .tscn file. parent_path: path inside the scene tree, e.g. /root or /root/Main."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "scene_path": {"type": "string", "description": "Scene file path, e.g. res://main.tscn or main.tscn"},
                    "parent_path": {"type": "string", "description": "Node path of parent in scene, e.g. /root or /root/Main", "default": "/root"},
                    "node_type": {"type": "string", "description": "Built-in Godot class only: Node, Node2D, Button, Label, CharacterBody2D, Sprite2D, etc."},
                    "node_name": {"type": "string", "description": "Optional name for the new node."},
                },
                "required": ["scene_path", "node_type"],
            },
            handler=_tool_create_node,
        ),
        ToolDef(
            name="modify_attribute",
            description=(
                "Set an attribute/property on a target. Use target_type to choose: "
                "'node' = property on a node in a scene (scene_path, node_path, attribute, value); "
                "'import' = key in the .import file [params] for a resource (path, attribute, value). "
                "Examples: node position, text; import compress (SVG lossless), mipmaps."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "target_type": {"type": "string", "description": "Either 'node' or 'import'."},
                    "attribute": {"type": "string", "description": "Property/key name (e.g. position, compress, text)."},
                    "value": {"description": "New value (number, string, bool, or [x,y] for vectors)."},
                    "scene_path": {"type": "string", "description": "Required if target_type=node. Scene file path, e.g. res://main.tscn"},
                    "node_path": {"type": "string", "description": "Required if target_type=node. Path to the node inside the scene, e.g. /root/Sprite"},
                    "path": {"type": "string", "description": "Required if target_type=import. Resource path, e.g. res://icon.svg"},
                },
                "required": ["target_type", "attribute", "value"],
            },
            handler=_tool_modify_attribute,
        ),
        ToolDef(
            name="read_file",
            description=(
                "Read the full contents of a project file. Use this whenever you need to see the current "
                "content of a file (e.g. before editing, or when the user asks what's in a file). "
                "You will receive the file content in the tool result. Path must be under res://, e.g. res://scripts/player.gd."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Project path, e.g. res://scripts/foo.gd or res://player.gd. Must start with res:// or be under the project.",
                    },
                },
                "required": ["path"],
            },
            handler=_tool_read_file,
        ),
        ToolDef(
            name="delete_file",
            description="Delete a file from the project (res://...).",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/old.gd"},
                },
                "required": ["path"],
            },
            handler=_tool_delete_file,
        ),
        ToolDef(
            name="list_directory",
            description="List files and folders in a directory under res://.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory path, e.g. res:// or res://scripts", "default": "res://"},
                    "recursive": {"type": "boolean", "description": "List recursively.", "default": False},
                    "max_entries": {"type": "integer", "description": "Max number of returned entries.", "default": 250, "minimum": 1, "maximum": 2000},
                    "max_depth": {"type": "integer", "description": "Max recursion depth if recursive.", "default": 6, "minimum": 0, "maximum": 20},
                },
            },
            handler=_tool_list_directory,
        ),
        ToolDef(
            name="search_files",
            description="Search for a text query inside project files under res:// (grep: finds files containing the text).",
            parameters={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Text to search for inside files."},
                    "root_path": {"type": "string", "description": "Directory to search under.", "default": "res://"},
                    "extensions": {"type": "array", "items": {"type": "string"}, "description": "Optional extension filters like ['.gd','.tscn'].", "default": []},
                    "max_matches": {"type": "integer", "description": "Max number of file matches.", "default": 50, "minimum": 1, "maximum": 500},
                },
                "required": ["query"],
            },
            handler=_tool_search_files,
        ),
        ToolDef(
            name="list_files",
            description=(
                "List file paths under res:// by optional extension(s), without searching file contents. "
                "Use this to find all files of a type (e.g. all .svg, .png, .tscn). Returns paths only."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory to list, e.g. res:// or res://assets", "default": "res://"},
                    "recursive": {"type": "boolean", "description": "List recursively.", "default": True},
                    "extensions": {"type": "array", "items": {"type": "string"}, "description": "Filter by extension, e.g. ['.svg'], ['.png','.jpg']. Omit for all files.", "default": []},
                    "max_entries": {"type": "integer", "description": "Max paths to return.", "default": 500, "minimum": 1, "maximum": 2000},
                },
            },
            handler=_tool_list_files,
        ),
        ToolDef(
            name="read_import_options",
            description=(
                "Read the .import file for a resource (e.g. res://icon.svg). Returns the file content so you can see current import options. "
                "Import options control how Godot imports assets (e.g. SVG compression, texture mipmaps)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Resource path, e.g. res://icon.svg (the .import file read is path.import)."},
                },
                "required": ["path"],
            },
            handler=_tool_read_import_options,
        ),
        ToolDef(
            name="lint_file",
            description=(
                "Run the Godot script linter on a project file (e.g. res://player.gd). "
                "Use when the user asks to lint a file or check for errors. The linter output is shown in the editor."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path to the script, e.g. res://scripts/foo.gd"},
                },
                "required": ["path"],
            },
            handler=_tool_lint_file,
        ),
    ]


def get_openai_tools_payload() -> List[Dict[str, Any]]:
    """
    Convert internal ToolDef objects into the 'tools' payload expected by
    OpenAI Responses tool-calling APIs.
    """
    tools_payload: List[Dict[str, Any]] = []
    for t in get_registered_tools():
        tools_payload.append(
            {
                "type": "function",
                "name": t.name,
                "description": t.description,
                "parameters": t.parameters,
            }
        )
    return tools_payload


def dispatch_tool_call(name: str, arguments: Dict[str, Any]) -> Any:
    """
    Execute the backend implementation for a named tool.
    """
    for t in get_registered_tools():
        if t.name == name:
            return t.handler(arguments)
    raise ValueError(f"Unknown tool: {name}")

