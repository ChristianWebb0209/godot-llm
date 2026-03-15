"""
Pydantic AI agent for Godot RAG + tools.
The agent runs the tool loop; tools delegate to execute_tool which handles backend vs client execution.
"""
import os
from typing import Any, List, Optional

from pydantic_ai import Agent, RunContext

from .deps import GodotQueryDeps
from .runner import execute_tool

# Default model (Responses API). Override via env OPENAI_MODEL or per-run.
DEFAULT_MODEL = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

GODOT_AGENT_SYSTEM_PROMPT = (
    "You are in AGENT MODE. You MUST use editor tools to fix, edit, or create files—do not only describe changes or suggest code for the user to copy. "
    "When the user asks to fix a file (e.g. 'fix enemy.gd', 'fix lint errors', 'fix the errors'), call read_file(path) to get the current contents, then use apply_patch(path, old_string, new_string) or write_file(path, content) to apply the fix. "
    "Never respond with only a description of the fix; always call the tools so the changes are applied in the user's Godot editor.\n\n"
    "You are a Godot 4.x development assistant. "
    "You have access to:\n"
    "- Retrieved documentation (the 'docs' collection, scraped from the official Godot manuals).\n"
    "- Retrieved example project code snippets (the 'project_code' collection, non-canonical examples).\n"
    "- Search tools: 'search_docs' and 'search_project_code' to refine your search. "
    "If you need full script examples for specific node types (e.g. CharacterBody2D, Control), call 'request_component_context' with those component names.\n"
    "- Editor tools (executed in the user's Godot editor). Use these first when the user asks to fix or edit a file:\n"
    "  - read_file(path): Call this to read the current contents of any project file (e.g. res://player.gd, res://scripts/enemy.gd). "
    "You WILL receive the full file content in the tool result. Always call read_file when asked to fix or edit a file; do not guess or assume.\n"
    "  - apply_patch(path, old_string, new_string): small targeted edits. Use for fixes: pass the exact old_string to replace and the new_string. Prefer over write_file for edits to existing files.\n"
    "  - write_file(path, content): overwrite file with full content. Use when apply_patch is not suitable (large replacements).\n"
    "  - create_file(path, content?): create an empty file at path; content is optional. Then use write_file to add content.\n"
    "  - create_script(path, extends_class, initial_content, template?): create a GDScript or C# script; use template (e.g. character_2d) for boilerplate.\n"
    "  - delete_file(path): delete a project file.\n"
    "  - list_directory(path, recursive, max_entries): list entries (files and dirs) in a folder.\n"
    "  - list_files(path, recursive, extensions, max_entries): list only file paths, optionally filtered by extension.\n"
    "  - search_files(query, root_path, extensions): grep—find files whose content contains the query text.\n"
    "  - project_structure(prefix, max_paths, max_depth): list indexed project file paths under a prefix.\n"
    "  - find_scripts_by_extends(extends_class): find scripts that extend a class (e.g. CharacterBody2D).\n"
    "  - find_references_to(res_path): find files that reference a given path.\n"
    "  - read_import_options(path): read the .import file for a resource.\n"
    "  - modify_attribute(target_type, attribute, value, ...): set an attribute on a target (node or import).\n"
    "  - create_node(scene_path, parent_path, node_type, node_name): add a node to a scene. Omit scene_path (or use 'current') for the current open scene.\n"
    "  - To attach a script to a node: create_script(path, extends_class, initial_content), then modify_attribute(target_type='node', scene_path=..., node_path=..., attribute='script', value='res://path/to/script.gd').\n\n"
    "Tool usage rules:\n"
    "- For NEW files: use create_script (with template when applicable) or create_file(path) then write_file(path, content). For EXISTING files: use apply_patch(path, old_string, new_string) for small edits; use write_file only for large replacements. You will receive the written content in the tool result; do not call read_file to verify.\n"
    "- When the user asks you to create or change something in the scene (nodes, player, scripts, attributes), USE the editor tools—call create_node, create_script, modify_attribute—so the changes happen in the editor. Do NOT only provide code for the user to run manually.\n"
    "- Match 2D vs 3D: the context will say whether the current scene is 2D or 3D. Use only node types that match (e.g. CharacterBody2D in 2D, CharacterBody3D in 3D).\n"
    "- To see what is in a file, call read_file(path). For new files (context may say 'file does not exist'), do not read_file; create with create_script or create_file then write_file.\n"
    "- When the user asks to fix, edit, or lint a specific file by name (e.g. 'fix lint in enemy.gd', 'fix enemy.gd'), you MUST call read_file(res://path) for that file to get its current contents before answering—never assume a file is empty from context. If the path is unclear, use search_files(query, root_path, ['.gd']) or list_files to find it, then read_file.\n"
    "- Use search_docs / search_project_code when you need more documentation or code examples. "
    "If context is missing for a component type, or the user asks for more examples, call request_component_context(components=[...]) to get full script examples.\n"
    "- For new files, create_file(path) may have empty content; then write_file(path, content). Never leave a user-visible file as placeholder; use write_file or append_to_file to add the real content.\n"
    "When you are satisfied, return a final answer to the user."
)


def _run_tool(ctx: RunContext[GodotQueryDeps], name: str, **kwargs: Any) -> Any:
    """Forward to execute_tool; used by all tool wrappers."""
    return execute_tool(name, dict(kwargs), ctx.deps)


# --- Tool wrappers: same names and parameters as ToolDef for schema compatibility ---

def search_docs(ctx: RunContext[GodotQueryDeps], query: str, top_k: int = 5) -> Any:
    """Search the indexed Godot documentation for relevant pages/snippets."""
    return _run_tool(ctx, "search_docs", query=query, top_k=top_k)


def search_project_code(
    ctx: RunContext[GodotQueryDeps],
    query: str,
    language: Optional[str] = None,
    top_k: int = 5,
) -> Any:
    """Search the indexed project_code collection for relevant scripts or shaders."""
    return _run_tool(ctx, "search_project_code", query=query, language=language, top_k=top_k)


def request_component_context(
    ctx: RunContext[GodotQueryDeps],
    components: List[str],
    language: Optional[str] = None,
    max_scripts_per_component: int = 3,
) -> Any:
    """Request full script examples for specific node/component types (extends classes)."""
    return _run_tool(
        ctx,
        "request_component_context",
        components=components,
        language=language,
        max_scripts_per_component=max_scripts_per_component,
    )


def create_file(
    ctx: RunContext[GodotQueryDeps],
    path: str,
    content: str = "",
    overwrite: bool = False,
) -> Any:
    """Create an empty file at path. Prefer create_file(path) then write_file(path, content)."""
    return _run_tool(ctx, "create_file", path=path, content=content, overwrite=overwrite)


def write_file(ctx: RunContext[GodotQueryDeps], path: str, content: str) -> Any:
    """Overwrite a file with new content. Creates the file if it does not exist."""
    return _run_tool(ctx, "write_file", path=path, content=content)


def append_to_file(ctx: RunContext[GodotQueryDeps], path: str, content: str) -> Any:
    """Append content to the end of a file. Creates the file if it does not exist."""
    return _run_tool(ctx, "append_to_file", path=path, content=content)


def apply_patch(
    ctx: RunContext[GodotQueryDeps],
    path: str,
    old_string: str = "",
    new_string: str = "",
    diff: str = "",
) -> Any:
    """Edit a file by replacing old_string with new_string, or pass a unified diff."""
    return _run_tool(ctx, "apply_patch", path=path, old_string=old_string, new_string=new_string, diff=diff)


def create_script(
    ctx: RunContext[GodotQueryDeps],
    path: str,
    language: str = "gdscript",
    extends_class: str = "Node",
    initial_content: str = "",
    template: str = "",
) -> Any:
    """Create a new GDScript or C# script file with one extends line and initial content."""
    return _run_tool(
        ctx,
        "create_script",
        path=path,
        language=language,
        extends_class=extends_class,
        initial_content=initial_content,
        template=template,
    )


def create_node(
    ctx: RunContext[GodotQueryDeps],
    node_type: str,
    scene_path: str = "",
    parent_path: str = "/root",
    node_name: str = "",
) -> Any:
    """Add a new node to a scene. Omit scene_path (or use 'current') for the current open scene."""
    return _run_tool(
        ctx,
        "create_node",
        node_type=node_type,
        scene_path=scene_path,
        parent_path=parent_path,
        node_name=node_name,
    )


def modify_attribute(
    ctx: RunContext[GodotQueryDeps],
    target_type: str,
    attribute: str,
    value: Any,
    scene_path: str = "",
    node_path: str = "",
    path: str = "",
) -> Any:
    """Set an attribute on a target (node or import)."""
    return _run_tool(
        ctx,
        "modify_attribute",
        target_type=target_type,
        attribute=attribute,
        value=value,
        scene_path=scene_path,
        node_path=node_path,
        path=path,
    )


def read_file(ctx: RunContext[GodotQueryDeps], path: str) -> Any:
    """Read the full contents of a project file. Use before editing or when the user asks what's in a file."""
    return _run_tool(ctx, "read_file", path=path)


def delete_file(ctx: RunContext[GodotQueryDeps], path: str) -> Any:
    """Delete a file from the project (res://...)."""
    return _run_tool(ctx, "delete_file", path=path)


def list_directory(
    ctx: RunContext[GodotQueryDeps],
    path: str = "res://",
    recursive: bool = False,
    max_entries: int = 250,
    max_depth: int = 6,
) -> Any:
    """List files and folders in a directory under res://."""
    return _run_tool(ctx, "list_directory", path=path, recursive=recursive, max_entries=max_entries, max_depth=max_depth)


def search_files(
    ctx: RunContext[GodotQueryDeps],
    query: str,
    root_path: str = "res://",
    extensions: Optional[List[str]] = None,
    max_matches: int = 50,
) -> Any:
    """Search for a text query inside project files under res:// (grep)."""
    return _run_tool(
        ctx,
        "search_files",
        query=query,
        root_path=root_path,
        extensions=extensions or [],
        max_matches=max_matches,
    )


def list_files(
    ctx: RunContext[GodotQueryDeps],
    path: str = "res://",
    recursive: bool = True,
    extensions: Optional[List[str]] = None,
    max_entries: int = 500,
) -> Any:
    """List file paths under res:// by optional extension(s), without searching file contents."""
    return _run_tool(
        ctx,
        "list_files",
        path=path,
        recursive=recursive,
        extensions=extensions or [],
        max_entries=max_entries,
    )


def read_import_options(ctx: RunContext[GodotQueryDeps], path: str) -> Any:
    """Read the .import file for a resource (e.g. res://icon.svg)."""
    return _run_tool(ctx, "read_import_options", path=path)


def lint_file(ctx: RunContext[GodotQueryDeps], path: str) -> Any:
    """Run the Godot script linter on a project file."""
    return _run_tool(ctx, "lint_file", path=path)


def project_structure(
    ctx: RunContext[GodotQueryDeps],
    prefix: str = "res://",
    max_paths: int = 300,
    max_depth: Optional[int] = None,
) -> Any:
    """List indexed project file paths under a prefix."""
    return _run_tool(ctx, "project_structure", prefix=prefix, max_paths=max_paths, max_depth=max_depth)


def find_scripts_by_extends(ctx: RunContext[GodotQueryDeps], extends_class: str) -> Any:
    """Find script files that extend a given class (e.g. CharacterBody2D, Node)."""
    return _run_tool(ctx, "find_scripts_by_extends", extends_class=extends_class)


def find_references_to(ctx: RunContext[GodotQueryDeps], res_path: str) -> Any:
    """Find files that reference a given path (e.g. a scene or script)."""
    return _run_tool(ctx, "find_references_to", res_path=res_path)


def get_recent_changes(ctx: RunContext[GodotQueryDeps], limit: int = 20) -> Any:
    """Return the last N edit events (what files were recently created/modified by the AI)."""
    return _run_tool(ctx, "get_recent_changes", limit=limit)


def grep_search(
    ctx: RunContext[GodotQueryDeps],
    pattern: str = "",
    query: str = "",
    root_path: str = "res://",
    extensions: Optional[List[str]] = None,
    max_matches: int = 100,
    use_regex: bool = True,
) -> Any:
    """Search project files with a regex or exact pattern."""
    return _run_tool(
        ctx,
        "grep_search",
        pattern=pattern or query,
        query=query,
        root_path=root_path,
        extensions=extensions or [],
        max_matches=max_matches,
        use_regex=use_regex,
    )


def fetch_url(ctx: RunContext[GodotQueryDeps], url: str) -> Any:
    """Fetch the content of a URL via HTTP GET (e.g. docs, API page)."""
    return _run_tool(ctx, "fetch_url", url=url)


def run_terminal_command(ctx: RunContext[GodotQueryDeps], command: str, timeout_seconds: int = 60) -> Any:
    """Run a shell command on the user's machine. Captures stdout, stderr, and exit code."""
    return _run_tool(ctx, "run_terminal_command", command=command, timeout_seconds=timeout_seconds)


def run_godot_headless(
    ctx: RunContext[GodotQueryDeps],
    scene_path: str = "",
    script_path: str = "",
    timeout_seconds: int = 30,
) -> Any:
    """Run Godot headlessly with a scene or script path."""
    return _run_tool(
        ctx,
        "run_godot_headless",
        scene_path=scene_path,
        script_path=script_path,
        timeout_seconds=timeout_seconds,
    )


def run_scene(ctx: RunContext[GodotQueryDeps], scene_path: str, timeout_seconds: int = 30) -> Any:
    """Run a Godot scene headlessly and capture output/errors."""
    return _run_tool(ctx, "run_scene", scene_path=scene_path, timeout_seconds=timeout_seconds)


def get_node_tree(ctx: RunContext[GodotQueryDeps], scene_path: str = "") -> Any:
    """Get the scene tree structure for the current open scene or a given .tscn path."""
    return _run_tool(ctx, "get_node_tree", scene_path=scene_path)


def get_signals(
    ctx: RunContext[GodotQueryDeps],
    node_type: str = "",
    script_path: str = "",
) -> Any:
    """List available signals for a node type or script."""
    return _run_tool(ctx, "get_signals", node_type=node_type, script_path=script_path)


def connect_signal(
    ctx: RunContext[GodotQueryDeps],
    scene_path: str,
    node_path: str,
    signal_name: str,
    callable_target: str = "",
) -> Any:
    """Connect a signal on a node to a callable."""
    return _run_tool(
        ctx,
        "connect_signal",
        scene_path=scene_path,
        node_path=node_path,
        signal_name=signal_name,
        callable_target=callable_target,
    )


def get_export_vars(
    ctx: RunContext[GodotQueryDeps],
    script_path: str = "",
    node_path: str = "",
    scene_path: str = "",
) -> Any:
    """List @export variables for a script or node."""
    return _run_tool(
        ctx,
        "get_export_vars",
        script_path=script_path,
        node_path=node_path,
        scene_path=scene_path,
    )


def search_asset_library(
    ctx: RunContext[GodotQueryDeps],
    filter: str = "",
    query: str = "",
    godot_version: str = "4.2",
    max_results: int = 20,
) -> Any:
    """Search the Godot Asset Library for addons/plugins by keyword."""
    return _run_tool(
        ctx,
        "search_asset_library",
        filter=filter or query,
        query=query,
        godot_version=godot_version,
        max_results=max_results,
    )


def get_project_settings(ctx: RunContext[GodotQueryDeps]) -> Any:
    """Read project.godot settings (key-value by section)."""
    return _run_tool(ctx, "get_project_settings")


def get_autoloads(ctx: RunContext[GodotQueryDeps]) -> Any:
    """List autoloaded singletons from project.godot."""
    return _run_tool(ctx, "get_autoloads")


def get_input_map(ctx: RunContext[GodotQueryDeps]) -> Any:
    """Read the input map from project.godot (action names and bound keys)."""
    return _run_tool(ctx, "get_input_map")


def check_errors(ctx: RunContext[GodotQueryDeps]) -> Any:
    """Return the current editor Errors/Warnings panel content."""
    return _run_tool(ctx, "check_errors")


# All tools in the same order as get_registered_tools() for consistency.
GODOT_AGENT_TOOLS = [
    search_docs,
    search_project_code,
    request_component_context,
    create_file,
    write_file,
    append_to_file,
    apply_patch,
    create_script,
    create_node,
    modify_attribute,
    read_file,
    delete_file,
    list_directory,
    search_files,
    list_files,
    read_import_options,
    lint_file,
    project_structure,
    find_scripts_by_extends,
    find_references_to,
    get_recent_changes,
    grep_search,
    fetch_url,
    run_terminal_command,
    run_godot_headless,
    run_scene,
    get_node_tree,
    get_signals,
    connect_signal,
    get_export_vars,
    search_asset_library,
    get_project_settings,
    get_autoloads,
    get_input_map,
    check_errors,
]


def create_godot_agent(
    model: Optional[str] = None,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
) -> Agent[GodotQueryDeps, str]:
    """
    Create the Godot RAG agent with tools.
    Uses OpenAI Responses API. Pass api_key/base_url for per-run overrides (e.g. from plugin settings).
    """
    model_name = model or DEFAULT_MODEL
    # Use openai-responses: prefix so Pydantic AI uses Responses API
    model_id = f"openai-responses:{model_name}" if ":" not in model_name else model_name
    agent = Agent(
        model_id,
        deps_type=GodotQueryDeps,
        instructions=GODOT_AGENT_SYSTEM_PROMPT,
        tools=GODOT_AGENT_TOOLS,
    )
    return agent


# Singleton agent (default env); main can replace or use create_godot_agent for overrides.
godot_agent = create_godot_agent()
