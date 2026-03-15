from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

from ..rag_core import SourceChunk, _collect_top_docs, _collect_code_results, _collect_code_by_extends
from .context import format_component_scripts_block, SCRAPED_CODE_DISCLAIMER


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


def _tool_request_component_context(args: Dict[str, Any]) -> Dict[str, Any]:
    """
    Fetch full script examples for specific node/component types (extends classes).
    Use when the AI needs more context on how to implement a given component
    (e.g. CharacterBody2D, Control, Camera3D) or when the user asks for more examples.
    """
    raw = args.get("components") or args.get("component")
    if isinstance(raw, str):
        components = [s.strip() for s in raw.split(",") if s.strip()]
    elif isinstance(raw, list):
        components = [str(c).strip() for c in raw if str(c).strip()]
    else:
        components = []
    if not components:
        return {
            "error": "components is required: list of node types (e.g. ['CharacterBody2D', 'Control']) or comma-separated string.",
            "context_added": False,
        }
    language: Optional[str] = args.get("language") or None
    max_per: int = int(args.get("max_scripts_per_component", 3))
    max_per = max(1, min(5, max_per))
    blocks: List[str] = []
    for extends_class in components[:10]:
        if not extends_class or extends_class == "Node":
            continue
        try:
            scripts = _collect_code_by_extends(extends_class, language=language, max_scripts=max_per)
            block = format_component_scripts_block(extends_class, scripts)
            if block:
                blocks.append(block)
        except Exception:
            continue
    if not blocks:
        return {
            "context_added": False,
            "components_requested": components,
            "message": "No example scripts found for the requested component types. Try search_project_code with a query instead.",
        }
    return {
        "context_added": True,
        "components_requested": components,
        "formatted_blocks": SCRAPED_CODE_DISCLAIMER.strip() + "\n\n" + "\n\n".join(blocks),
        "message": "Use the formatted_blocks below as additional reference for the requested component types. (Code is from various repos, not the user's project.)",
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


def _tool_append_to_file(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    content = args.get("content", "")
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    return _editor_payload("append_to_file", path=path, content=content)


def _tool_apply_patch(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    old_string = args.get("old_string", "")
    new_string = args.get("new_string", "")
    diff = (args.get("diff") or "").strip()
    if not path:
        return {"error": "path is required", "execute_on_client": False}
    payload = {"path": path}
    if diff:
        payload["diff"] = diff
    else:
        payload["old_string"] = old_string
        payload["new_string"] = new_string
    return _editor_payload("apply_patch", **payload)


def _tool_create_script(args: Dict[str, Any]) -> Dict[str, Any]:
    path = (args.get("path") or "").strip()
    language = (args.get("language") or "gdscript").strip().lower()
    extends_class = (args.get("extends_class") or "Node").strip()
    initial_content = args.get("initial_content", "")
    template = (args.get("template") or "").strip().lower()
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
        template=template or None,
    )


def _normalize_scene_path(path: str) -> str:
    p = (path or "").strip()
    if not p:
        return p
    if not p.startswith("res://"):
        p = "res://" + p
    return p


def _tool_create_node(args: Dict[str, Any]) -> Dict[str, Any]:
    scene_path_raw = (args.get("scene_path") or "").strip()
    # Empty or "current" means use current open scene (injected by main.py from active_scene_path, or plugin resolves/creates).
    if not scene_path_raw or scene_path_raw.lower() == "current":
        scene_path = "current"
    else:
        scene_path = _normalize_scene_path(scene_path_raw)
    parent_path = (args.get("parent_path") or "/root").strip()
    node_type = (args.get("node_type") or "Node").strip()
    node_name = (args.get("node_name") or "").strip()
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
        if not path.startswith("res://"):
            path = "res://" + path
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


def _tool_project_structure(args: Dict[str, Any]) -> Dict[str, Any]:
    """Server-only: list indexed file paths under a prefix. Requires project_root_abs from context."""
    return {
        "error": "Project structure is available when the editor has a project open (project_root_abs sent). Open a Godot project and try again.",
        "execute_on_client": False,
    }


def _tool_find_scripts_by_extends(args: Dict[str, Any]) -> Dict[str, Any]:
    """Server-only: find scripts that extend a class. Requires project_root_abs from context."""
    return {
        "error": "Find scripts by extends is available when the editor has a project open. Open a Godot project and try again.",
        "execute_on_client": False,
    }


def _tool_find_references_to(args: Dict[str, Any]) -> Dict[str, Any]:
    """Server-only: find files that reference a given path. Requires project_root_abs from context."""
    return {
        "error": "Find references is available when the editor has a project open. Open a Godot project and try again.",
        "execute_on_client": False,
    }




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
        ToolDef(
            name="request_component_context",
            description=(
                "Request more context: full script examples for specific node/component types (extends classes). "
                "Call this when you need more example code for a component (e.g. CharacterBody2D, Control, Camera3D) "
                "or when the user asks for more examples. Returns formatted full-script blocks you can use as reference."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "components": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "List of node types (extends classes), e.g. ['CharacterBody2D', 'Control'].",
                    },
                    "language": {
                        "type": "string",
                        "description": "Optional: 'gdscript' or 'csharp'.",
                    },
                    "max_scripts_per_component": {
                        "type": "integer",
                        "description": "Max full scripts to fetch per component (1-5).",
                        "default": 3,
                        "minimum": 1,
                        "maximum": 5,
                    },
                },
                "required": ["components"],
            },
            handler=_tool_request_component_context,
        ),
        # --- Editor tools (executed on Godot client) ---
        ToolDef(
            name="create_file",
            description=(
                "Create an empty file at path. Prefer create_file(path) then write_file(path, content) so you can write in one or more steps. "
                "Omit content or pass empty for create-only. If overwrite is false, the file must not exist."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/foo.gd"},
                    "content": {"type": "string", "description": "Optional initial content; omit or empty for create-only.", "default": ""},
                    "overwrite": {"type": "boolean", "description": "Overwrite if exists.", "default": False},
                },
                "required": ["path"],
            },
            handler=_tool_create_file,
        ),
        ToolDef(
            name="write_file",
            description=(
                "Overwrite a file with new content. Creates the file if it does not exist. "
                "Use after create_file for new files, or when apply_patch is not suitable for large replacements. "
                "For .gd files: the file already has one 'extends ClassName' at the top; do not add another extends line."
            ),
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
            name="append_to_file",
            description="Append content to the end of a file. Creates the file if it does not exist. Use for incremental writes.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/foo.gd"},
                    "content": {"type": "string", "description": "Content to append to the file."},
                },
                "required": ["path", "content"],
            },
            handler=_tool_append_to_file,
        ),
        ToolDef(
            name="apply_patch",
            description=(
                "Edit a file by replacing the first occurrence of old_string with new_string, or pass a unified diff. "
                "Prefer over write_file for edits to existing files (fewer tokens). Use for small, targeted edits in scripts or scenes. "
                "For .gd files: do not add a second 'extends' line; the script already has one at the top."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path to the file."},
                    "old_string": {"type": "string", "description": "Exact text to find and replace (omit if using diff)."},
                    "new_string": {"type": "string", "description": "Replacement text (omit if using diff)."},
                    "diff": {"type": "string", "description": "Optional unified diff string instead of old_string/new_string."},
                },
                "required": ["path"],
            },
            handler=_tool_apply_patch,
        ),
        ToolDef(
            name="create_script",
            description=(
                "Create a new GDScript or C# script file with one extends line and initial content. "
                "Use template (e.g. character_2d, character_3d, control) to fill boilerplate so you only supply initial_content for the unique logic. "
                "The created file will have exactly one 'extends ClassName' at the top; when later editing with write_file or apply_patch, never add another extends. "
                "To attach the script to a node, after creating the script call modify_attribute(target_type='node', scene_path=..., node_path=..., attribute='script', value='res://path/to/script.gd')."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Project path, e.g. res://scripts/player.gd"},
                    "language": {"type": "string", "description": "gdscript or csharp", "default": "gdscript"},
                    "extends_class": {"type": "string", "description": "Base class, e.g. Node, CharacterBody2D (ignored if template is set).", "default": "Node"},
                    "initial_content": {"type": "string", "description": "Optional body content; with template this is the unique logic only.", "default": ""},
                    "template": {"type": "string", "description": "Optional: character_2d, character_3d, control, area_2d, area_3d, node. Fills boilerplate.", "default": ""},
                },
                "required": ["path"],
            },
            handler=_tool_create_script,
        ),
        ToolDef(
            name="create_node",
            description=(
                "Add a new node to a scene. Executes in the Godot editor: opens the scene, adds the node, saves. "
                "ALWAYS attach to the current scene: omit scene_path (or use 'current'). parent_path defaults to /root. "
                "Match the scene dimension: in a 2D scene use Node2D, CharacterBody2D, Sprite2D, CollisionShape2D, etc.; "
                "in a 3D scene use Node3D, CharacterBody3D, MeshInstance3D, etc. Do NOT use 3D types in a 2D scene or vice versa. "
                "To add custom behavior, create_script then modify_attribute(attribute='script', value='res://path/to/script.gd') on the node."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "scene_path": {"type": "string", "description": "Optional. Omit or use 'current' to use the current open scene (preferred). Or res://path/to/scene.tscn."},
                    "parent_path": {"type": "string", "description": "Node path of parent in scene; default /root (scene root).", "default": "/root"},
                    "node_type": {"type": "string", "description": "Built-in Godot class only: Node, Node2D, Button, Label, CharacterBody2D, Sprite2D, etc."},
                    "node_name": {"type": "string", "description": "Optional name for the new node."},
                },
                "required": ["node_type"],
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
        ToolDef(
            name="project_structure",
            description=(
                "List indexed project file paths under a prefix (from the repo index). "
                "Use to see what files exist without reading them (e.g. 'where is Player?' or project layout)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "prefix": {"type": "string", "description": "res:// prefix, e.g. res:// or res://scripts", "default": "res://"},
                    "max_paths": {"type": "integer", "description": "Max paths to return.", "default": 300, "minimum": 1, "maximum": 1000},
                    "max_depth": {"type": "integer", "description": "Max path depth (segment count). Omit for no limit.", "minimum": 1, "maximum": 10},
                },
            },
            handler=_tool_project_structure,
        ),
        ToolDef(
            name="find_scripts_by_extends",
            description=(
                "Find script files that extend a given class (e.g. CharacterBody2D, Node). "
                "Returns paths to .gd/.cs files that contain 'extends ClassName'."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "extends_class": {"type": "string", "description": "Class name, e.g. CharacterBody2D, Control, Node"},
                },
                "required": ["extends_class"],
            },
            handler=_tool_find_scripts_by_extends,
        ),
        ToolDef(
            name="find_references_to",
            description=(
                "Find files that reference a given path (e.g. a scene or script). "
                "Uses the project index to return paths that reference the target (instances, scripts, res:// refs)."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "res_path": {"type": "string", "description": "Target path, e.g. res://player.tscn or res://scripts/player.gd"},
                },
                "required": ["res_path"],
            },
            handler=_tool_find_references_to,
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

