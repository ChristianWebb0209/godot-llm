import asyncio
import contextlib
import json
import logging
import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from dotenv import load_dotenv
from openai import OpenAI
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .rag_core import (
    SourceChunk,
    _collect_code_by_extends,
    _collect_code_results,
    _collect_top_docs,
    get_collections,
)
from .services.repo_indexing import (
    get_inbound_refs,
    get_most_referenced_res_paths,
    get_repo_index_stats,
    list_indexed_paths,
)
from .services.tools import (
    dispatch_tool_call,
    get_openai_tools_payload,
    get_registered_tools,
)
from .db import (
    create_edit_event,
    get_edit_event,
    get_usage_totals,
    init_db,
    list_edit_events,
    list_recent_file_changes,
    record_usage,
)
from .repair_memory import (
    create_lint_fix_record,
    format_fixes_for_prompt,
    search_lint_fixes,
)
from .context_builder import (
    build_context_usage,
    build_current_scene_scripts_context,
    build_ordered_blocks,
    build_related_files_context,
    blocks_to_user_content,
    extract_extends_from_script,
    format_component_scripts_block,
    get_context_limit,
    list_project_files,
    read_project_file,
    trim_text_to_tokens,
)
from .services.context import (
    append_project_file,
    apply_project_patch,
    apply_project_patch_unified,
    build_conversation_context,
    list_project_directory,
    search_project_files,
    write_project_file,
)
from .services.context.viewer import build_context_view
from .console_log import dim as _dim, cyan as _cyan, green as _green, yellow as _yellow


load_dotenv()  # Load environment variables from .env if present.

# Only show WARNING and above for watchfiles/reload — avoid info spam when files change
for _watch_log in ("watchfiles", "watchfiles.main", "uvicorn.reload"):
    logging.getLogger(_watch_log).setLevel(logging.WARNING)


def _asyncio_exception_handler(loop: asyncio.AbstractEventLoop, context: dict) -> None:
    """Suppress noisy CancelledError tracebacks on Ctrl+C shutdown."""
    exc = context.get("exception")
    if isinstance(exc, asyncio.CancelledError):
        return
    loop.default_exception_handler(context)


class _SuppressCancelledErrorFilter(logging.Filter):
    """Filter out ERROR logs for asyncio.CancelledError (clean Ctrl+C shutdown)."""

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno < logging.ERROR:
            return True
        if record.exc_info and record.exc_info[0] is not None:
            if record.exc_info[0] is asyncio.CancelledError:
                return False
        if "CancelledError" in (record.getMessage() or ""):
            return False
        return True


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(_asyncio_exception_handler)
    # Suppress ERROR-level tracebacks for CancelledError on shutdown (Ctrl+C)
    for name in ("uvicorn", "uvicorn.error", "starlette.routing", ""):
        log = logging.getLogger(name) if name else logging.root
        log.addFilter(_SuppressCancelledErrorFilter())
    try:
        yield
    except asyncio.CancelledError:
        pass
    finally:
        pass


app = FastAPI(title="Godot RAG Service", version="0.1.0", lifespan=lifespan)
init_db()


_openai_client: Optional[OpenAI] = None


# Approximate pricing for OpenAI models (USD per 1K tokens).
# Values taken from OpenAI pricing for gpt-4.1-mini:
# - $0.40 per 1M input tokens  => 0.0004 per 1K
# - $1.60 per 1M output tokens => 0.0016 per 1K
MODEL_PRICING: Dict[str, Dict[str, float]] = {
    "gpt-4.1-mini": {
        "input_per_1k": 0.0004,
        "output_per_1k": 0.0016,
    },
}


def _estimate_cost_usd(model: str, prompt_tokens: int, completion_tokens: int) -> float:
    pricing = MODEL_PRICING.get(model)
    if not pricing:
        return 0.0
    input_cost = (prompt_tokens / 1000.0) * pricing["input_per_1k"]
    output_cost = (completion_tokens / 1000.0) * pricing["output_per_1k"]
    return input_cost + output_cost


def _log_usage_and_cost(
    model: str,
    prompt_tokens: int,
    completion_tokens: int,
    context: str,
) -> None:
    total_tokens = prompt_tokens + completion_tokens
    cost = _estimate_cost_usd(model, prompt_tokens, completion_tokens)
    print(
        _cyan("usage")
        + " "
        + _dim(f"model={model} in={prompt_tokens} out={completion_tokens} total={total_tokens} ${cost:.4f}")
    )


def _log_llm_input(model: str, context: str, input_payload: Any) -> None:
    """Log a one-line summary of the LLM request. Set DEBUG_LLM_INPUT=1 to dump full payload."""
    if os.getenv("DEBUG_LLM_INPUT"):
        try:
            dumped = json.dumps(input_payload, ensure_ascii=False, indent=2)
        except Exception:
            dumped = str(input_payload)
        enc = getattr(sys.stdout, "encoding", None) or "utf-8"
        safe = dumped.encode(enc, errors="backslashreplace").decode(enc, errors="ignore")
        print(f"{_yellow('llm_input')} context={context} model={model}\n{safe}\n")
        return
    n_msgs = len(input_payload) if isinstance(input_payload, list) else 0
    total_chars = 0
    if isinstance(input_payload, list):
        for m in input_payload:
            if isinstance(m, dict) and "content" in m:
                c = m.get("content")
                total_chars += len(str(c)) if c else 0
    print(_dim(f"llm request model={model} context={context} messages={n_msgs} chars≈{total_chars}"))


def _log_rag_request(method_label: str, client_host: str, question: str, color_fn: Any = _green) -> None:
    q = (question.strip() or "")[:56]
    if len(question.strip()) > 56:
        q += "…"
    print(color_fn(method_label) + " " + _dim(f"{client_host} ") + _dim(f"{q!r}"))


def get_openai_client() -> Optional[OpenAI]:
    """
    Lazily create an OpenAI client using environment variables.
    Returns None if no OPENAI_API_KEY is configured.
    """
    global _openai_client
    if _openai_client is not None:
        return _openai_client

    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        return None

    base_url = os.getenv("OPENAI_BASE_URL")
    _openai_client = OpenAI(api_key=api_key, base_url=base_url or None)
    return _openai_client


def _openai_client_and_model(
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    model: Optional[str] = None,
) -> Tuple[Optional[OpenAI], str]:
    """
    Return (client, model) for LLM calls. Uses request overrides if provided,
    otherwise env. model is always a non-empty string.
    """
    default_model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")
    if api_key:
        client = OpenAI(api_key=api_key, base_url=base_url or None)
        return client, model or default_model
    client = get_openai_client()
    return client, model or default_model


class QueryContext(BaseModel):
    engine_version: Optional[str] = None
    # Preferred script language for answers, based on the active file.
    language: Optional[str] = None  # "gdscript" | "csharp"
    selected_node_type: Optional[str] = None
    current_script: Optional[str] = None
    extra: Dict[str, Any] = {}


class QueryRequest(BaseModel):
    question: str
    context: Optional[QueryContext] = None
    top_k: int = 8
    max_tool_rounds: Optional[int] = None  # default 5 when None; max tool-call rounds per request
    # Optional overrides from plugin settings (take precedence over env).
    api_key: Optional[str] = None
    model: Optional[str] = None
    base_url: Optional[str] = None


class QueryResponse(BaseModel):
    answer: str
    snippets: List[SourceChunk]
    context_usage: Optional[Dict[str, Any]] = None


class ToolCallResult(BaseModel):
    tool_name: str
    arguments: Dict[str, Any]
    output: Any


class QueryResponseWithTools(QueryResponse):
    # Optional structured record of any tools the model asked us to run.
    tool_calls: List[ToolCallResult] = []


# Path keywords -> Chroma component_type values (must match analyze_project indexing).
# Index stores role (e.g. basic_enemy_ai) or first tag (e.g. enemy); we pass both so retrieval finds all.
_PATH_TO_COMPONENT_TYPES: List[Tuple[str, ...]] = [
    ("enemy", "basic_enemy_ai"),  # path has enemy/mob/ai
    ("player", "2d_player_controller"),
    ("ui", "pause_menu_ui"),
    ("editor", "editor_plugin"),
    ("main",),
    ("level",),
]
_PATH_KEYWORDS_FOR_HINT: List[Tuple[str, str]] = [
    ("enemy", "enemy"), ("mob", "enemy"), ("ai", "enemy"),
    ("player", "player"), ("hero", "player"),
    ("menu", "ui"), ("ui", "ui"), ("hud", "ui"), ("pause", "ui"),
    ("editor", "editor"),
    ("main", "main"), ("game", "main"),
    ("level", "level"), ("world", "level"), ("map", "level"),
]


def path_to_component_types(active_file_path: Optional[str]) -> Optional[List[str]]:
    """
    Derive Chroma component_type filter from the active file path so we retrieve
    relevant examples (e.g. enemy scripts when the user is editing a file with 'enemy' in the path).
    Returns a list of component_type values to pass to _collect_code_results(component_types=...).
    """
    if not active_file_path or not isinstance(active_file_path, str):
        return None
    path_lower = active_file_path.lower().strip()
    if path_lower.startswith("res://"):
        path_lower = path_lower[6:].lstrip("/")
    for keyword, bucket in _PATH_KEYWORDS_FOR_HINT:
        if keyword in path_lower:
            for tup in _PATH_TO_COMPONENT_TYPES:
                if tup[0] == bucket:
                    return list(tup)
            return [bucket]
    return None


def _call_llm_with_rag(
    question: str,
    context_language: Optional[str],
    docs: List[SourceChunk],
    code_snippets: List[SourceChunk],
    is_obscure: bool,
    client: Optional[OpenAI] = None,
    model: Optional[str] = None,
) -> str:
    """
    Call OpenAI chat completions to synthesize an answer from retrieved docs/code.
    Falls back to a verbose plain-text template if no API key is configured.
    """
    if client is None:
        client = get_openai_client()
    if model is None:
        model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

    # Build a verbose reasoning-oriented answer if no LLM is available.
    if client is None:
        lines: List[str] = []
        lines.append("This answer is grounded in your Godot docs and project code.\n")
        lines.append(f"Question: {question}\n")
        if context_language:
            lines.append(f"Preferred language: {context_language}\n")
        if docs:
            lines.append("\nRelevant documentation snippets:\n")
            for d in docs:
                lines.append(f"- {d.source_path}")
        if code_snippets:
            lines.append("\nRelevant project code snippets (ordered by relevance/importance):\n")
            for s in code_snippets:
                tags = s.metadata.get("tags", [])
                importance = s.metadata.get("importance", 0.0)
                lines.append(
                    f"- {s.source_path} (importance={importance}, tags={tags})"
                )
        if is_obscure:
            lines.append(
                "\nNote: This appears to be a more niche area of your codebase, "
                "so lower-importance snippets were also considered."
            )
        return "\n".join(lines)

    # Build structured context for the LLM.
    docs_block_lines: List[str] = []
    for d in docs:
        docs_block_lines.append(
            "Official docs snippet from the Godot 4.x manual:\n"
            f"[DOC] path={d.source_path} meta={d.metadata}\n{d.text_preview}\n"
        )
    code_block_lines: List[str] = []
    for s in code_snippets:
        code_block_lines.append(
            "Example project code snippet (not canonical API, use as inspiration only):\n"
            f"[CODE] path={s.source_path} meta={s.metadata}\n{s.text_preview}\n"
        )

    system_prompt = (
        "You are a Godot 4.x development assistant. "
        "You receive a user question plus retrieved documentation and real project code. "
        "The 'docs' collection is scraped from the official Godot manuals and is the "
        "authoritative source for engine behavior and APIs. The 'project_code' collection "
        "contains example scripts and shaders from a wide range of different open-source repos "
        "(not the user's project); they may reference project-specific types, addons, or paths. "
        "Treat them only as patterns and inspiration, not as canonical definitions or as code from the user's project. "
        "Use ONLY the provided context to answer. Prefer documentation when there is any "
        "conflict between docs and project code. Prefer higher-importance code snippets "
        "when multiple examples are relevant, but you may also rely on lower-importance "
        "snippets if the topic appears niche or under-documented. "
        "Always be explicit about your reasoning: explain which snippets you used "
        "and why, referencing them by their path. "
        "When writing code examples, default to the user's preferred language if given."
    )

    user_prompt_lines: List[str] = []
    user_prompt_lines.append(f"Question: {question}\n")
    if context_language:
        user_prompt_lines.append(f"Preferred language: {context_language}\n")
    if is_obscure:
        user_prompt_lines.append(
            "Heuristic: This seems like a more obscure area of the codebase; "
            "lower-importance snippets may also be relevant.\n"
        )
    if docs_block_lines:
        user_prompt_lines.append("\n=== Documentation Context ===\n")
        user_prompt_lines.extend(docs_block_lines)
    if code_block_lines:
        user_prompt_lines.append("\n=== Project Code Context ===\n")
        user_prompt_lines.extend(code_block_lines)
    user_prompt_lines.append(
        "\nPlease respond with:\n"
        "1) A concise answer.\n"
        "2) A short 'Reasoning' section explaining which docs/code you used and why.\n"
        "3) Code examples in the preferred language if applicable.\n"
    )

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": "\n".join(user_prompt_lines)},
    ]

    _log_llm_input(model=model, context="rag_answer", input_payload=messages)

    completion = client.chat.completions.create(
        model=model,
        messages=messages,
    )

    # Log token usage and estimated cost if available.
    usage = getattr(completion, "usage", None)
    if usage is not None:
        prompt_tokens = getattr(usage, "prompt_tokens", 0) or 0
        completion_tokens = getattr(usage, "completion_tokens", 0) or 0
        _log_usage_and_cost(
            model=model,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            context="rag_answer",
        )
        record_usage(model, prompt_tokens, completion_tokens)

    return completion.choices[0].message.content or ""


def _run_query_with_tools(
    question: str,
    context_language: Optional[str],
    request_context: Optional["QueryContext"],
    top_k: int,
    max_tool_rounds: int = 5,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    model_override: Optional[str] = None,
) -> Tuple[str, List[SourceChunk], List[ToolCallResult], Dict[str, Any]]:
    """
    Orchestrate a full query using:
      - Initial RAG retrieval for docs + code.
      - OpenAI tool calls for follow-up operations (searching again, etc.).

    Returns (final_answer, snippets_used, tool_calls_run, context_usage).
    """
    client, model = _openai_client_and_model(
        api_key=api_key, base_url=base_url, model=model_override
    )
    # Component-type hint from active file path (e.g. enemy in path -> retrieve enemy examples).
    active_script_for_rag = request_context.current_script if request_context else None
    component_types_from_path = path_to_component_types(active_script_for_rag)

    # If there is no LLM, fall back to the existing RAG-only path.
    if client is None:
        docs = _collect_top_docs(question, top_k=top_k)
        code_snippets = _collect_code_results(
            question=question,
            language=context_language,
            top_k=top_k,
            component_types=component_types_from_path,
        )
        is_obscure = len(code_snippets) < max(1, top_k // 3)
        answer = _call_llm_with_rag(
            question=question,
            context_language=context_language,
            docs=docs,
            code_snippets=code_snippets,
            is_obscure=is_obscure,
        )
        usage_obj = build_context_usage(model, [question])
        return answer, docs + code_snippets, [], {
            "model": usage_obj.model,
            "limit_tokens": usage_obj.limit_tokens,
            "estimated_prompt_tokens": usage_obj.estimated_prompt_tokens,
            "percent": usage_obj.percent,
        }

    # Initial RAG step (bias code retrieval by active file path, e.g. enemy examples when editing enemy script).
    docs = _collect_top_docs(question, top_k=top_k)
    code_snippets = _collect_code_results(
        question=question,
        language=context_language,
        top_k=top_k,
        component_types=component_types_from_path,
    )
    is_obscure = len(code_snippets) < max(1, top_k // 3)

    # --- Context builder (Stage 2): ordered blocks + budgets ---
    system_prompt = (
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

    # Extract active file info from request context (sent by the Godot editor).
    active_file_path = None
    active_file_text = None
    active_scene_path: Optional[str] = None
    scene_root_class: Optional[str] = None
    scene_dimension: Optional[str] = None
    scene_tree: Optional[str] = None
    errors_text = None
    selected_node_type: Optional[str] = None
    if request_context is not None:
        active_file_path = request_context.current_script or None
        extra = request_context.extra or {}
        active_file_text = extra.get("active_file_text") or None
        active_scene_path = (extra.get("active_scene_path") or "").strip() or None
        scene_root_class = (extra.get("scene_root_class") or "").strip() or None
        scene_dimension = (extra.get("scene_dimension") or "").strip().lower() or None
        scene_tree = (extra.get("scene_tree") or "").strip() or None
        errors_text = extra.get("errors_text") or extra.get("lint_output") or None
        project_root_abs = extra.get("project_root_abs") or None
        engine_version = request_context.engine_version or None
        selected_node_type = (request_context.selected_node_type or "").strip() or None
        exclude_block_keys_raw = extra.get("exclude_block_keys")
        exclude_block_keys = (
            list(exclude_block_keys_raw)
            if isinstance(exclude_block_keys_raw, (list, tuple))
            else []
        )
    else:
        project_root_abs = None
        engine_version = None
        exclude_block_keys = []

    # If plugin didn't send file text (or it's empty), read from disk.
    if project_root_abs and active_file_path and (not active_file_text or len(active_file_text) < 5):
        disk_text = read_project_file(project_root_abs, active_file_path)
        if disk_text:
            active_file_text = disk_text

    related_files: List[Tuple[str, str]] = []
    if project_root_abs and active_file_path and active_file_text:
        related_files = build_related_files_context(
            project_root_abs=project_root_abs,
            active_file_res_path=active_file_path,
            active_file_text=active_file_text,
            max_files=4,
        )
    # Prepend project core (most-referenced) files so the model always sees e.g. Player.
    if project_root_abs:
        try:
            core_paths = get_most_referenced_res_paths(
                project_root_abs=project_root_abs,
                limit=5,
                edge_types=("instances_scene", "attaches_script"),
            )
            seen_paths = {p for p, _ in related_files}
            core_entries: List[Tuple[str, str]] = []
            for res_path in core_paths:
                if res_path in seen_paths:
                    continue
                content = read_project_file(project_root_abs, res_path)
                if content:
                    core_entries.append(
                        (res_path, f"--- Project core (most referenced): {res_path} ---\n{content}")
                    )
                    seen_paths.add(res_path)
            max_related_total = 8
            related_files = (core_entries + related_files)[:max_related_total]
        except Exception:
            pass

    # Current scene scripts: parse open scene .tscn and attach all scripts in that scene (aggressive context).
    current_scene_scripts: List[Tuple[str, str]] = []
    if project_root_abs and active_scene_path and active_scene_path.strip().endswith((".tscn", ".scn")):
        try:
            current_scene_scripts = build_current_scene_scripts_context(
                project_root_abs=project_root_abs,
                scene_res_path=active_scene_path.strip(),
                max_scripts=12,
                max_tokens_per_script=1200,
                exclude_path=active_file_path,
            )
        except Exception:
            pass

    # Recency working set (SQLite): include the most recent diffs as lightweight context.
    recent_edits_text: List[str] = []
    try:
        recent = list_recent_file_changes(limit_edits=30, max_files=6)
        for r in recent:
            recent_edits_text.append(
                f"Edit #{r['edit_id']} ({r['trigger']}): {r['summary']}\n"
                f"File: {r['file_path']} ({r['change_type']}, +{r['lines_added']} -{r['lines_removed']})\n"
                f"{r['diff']}"
            )
    except Exception:
        pass

    retrieved_docs = [
        "Official docs snippet:\n"
        f"[DOC] path={d.source_path} meta={d.metadata}\n{d.text_preview}\n"
        for d in docs
    ]
    retrieved_code = [
        "Example project code snippet:\n"
        f"[CODE] path={s.source_path} meta={s.metadata}\n{s.text_preview}\n"
        for s in code_snippets
    ]
    # Build dedicated ENVIRONMENT block (high priority, never dropped).
    environment_parts: List[str] = []
    # Context legend: so the LLM knows what it's dealing with (user's project vs reference).
    environment_parts.append(
        "CONTEXT SOURCES: "
        "'Active file' = the file currently focused in the Godot editor (user's project, res:// path). "
        "'Related files' / 'Current scene scripts' / 'Open in editor' = also the user's project. "
        "'Retrieved documentation' = official Godot docs. "
        "'Retrieved project code' / 'Example scripts by type' = from other indexed repos (reference only, not the user's project). "
        "When editing or fixing a file, use the path shown (e.g. res://enemy.gd); call read_file(path) if you need full content."
    )
    if engine_version:
        environment_parts.append(f"engine: {engine_version}")
    if active_scene_path:
        environment_parts.append(f"Current scene (open in editor): {active_scene_path}. Use for create_node (or omit scene_path).")
    # File-preview context: when the user is clearly asking to create a new file/script, tell the model it does not exist.
    q_lower = question.strip().lower()
    if any(
        phrase in q_lower
        for phrase in ("create ", "add a script", "new script", "new file", "create a ", "make a script", "make a file")
    ):
        environment_parts.append(
            "The user may be asking to create a new script or file. That file does not exist yet. "
            "Use create_script or create_file then write_file; no need to call read_file before creating."
        )
    if scene_dimension == "2d":
        environment_parts.append("SCENE TYPE: 2D")
        environment_parts.append(
            "ALLOWED NODE TYPES: Node2D, CharacterBody2D, Sprite2D, CollisionShape2D, Camera2D, "
            "Label, Button, Control, TileMap, Area2D, StaticBody2D, etc. Do NOT use any Node3D/CharacterBody3D/3D types."
        )
    elif scene_dimension == "3d":
        environment_parts.append("SCENE TYPE: 3D")
        environment_parts.append(
            "ALLOWED NODE TYPES: Node3D, CharacterBody3D, MeshInstance3D, CollisionShape3D, Camera3D, "
            "Area3D, StaticBody3D, etc. Do NOT use any Node2D/CharacterBody2D/2D types."
        )
    if scene_root_class:
        environment_parts.append(f"Scene root class: {scene_root_class}.")
    if scene_tree:
        environment_parts.append("SCENE TREE:\n" + scene_tree)
    # Optional project.godot summary (main scene, autoloads).
    if project_root_abs:
        try:
            proj_text = read_project_file(project_root_abs, "res://project.godot", max_bytes=32_000)
            if proj_text:
                main_scene: Optional[str] = None
                autoloads: List[str] = []
                section = ""
                for raw in proj_text.splitlines():
                    line = raw.strip()
                    if not line or line.startswith(";") or line.startswith("#"):
                        continue
                    if line.startswith("[") and line.endswith("]"):
                        section = line.strip("[]")
                        continue
                    if "=" in line:
                        key, _, value = line.partition("=")
                        key, value = key.strip(), value.strip().strip('"').strip("'")
                        if section == "application" and key == "run/main_scene":
                            main_scene = value
                        elif section.startswith("autoload") and key:
                            autoloads.append(key)
                if main_scene:
                    environment_parts.append(f"Project main scene: {main_scene}")
                if autoloads:
                    environment_parts.append("Project autoloads: " + ", ".join(autoloads[:15]))
        except Exception:
            pass
    # Godot API efficiency: short tips so the model generates idiomatic, efficient code.
    environment_parts.append(
        "Godot API efficiency: Use _physics_process(delta) for movement; _process(delta) for UI/non-physics. "
        "Cache node refs (e.g. onready var x = $Path or get once in _ready()). Use signals for decoupling. "
        "Prefer move_and_slide/move_and_collide for physics bodies; use call_deferred when modifying scene tree from callbacks. "
        "GDScript (.gd) files have exactly one 'extends ClassName' line at the top; when editing or writing a .gd file, never add a second extends—the file already has one. "
        "When fixing lint: Godot reports one error at a time; lint is re-run after each fix, so you may receive another message with the next error—fix the current one; more may follow."
    )
    environment_text = "\n".join(environment_parts) if environment_parts else None

    optional_extras: List[str] = []
    if context_language:
        optional_extras.append(f"Preferred language: {context_language}")
    # Conversation history (plugin sends last N turns for multi-turn continuity).
    if request_context and request_context.extra:
        conv_raw = request_context.extra.get("conversation_history")
        if conv_raw is not None and isinstance(conv_raw, list) and len(conv_raw) > 0:
            conv_block = build_conversation_context(conv_raw)
            if conv_block:
                optional_extras.append("Recent conversation (for continuity):\n" + conv_block)
    # Open script tabs: first ~24 lines of top 5 scripts open in the Godot editor (aggressive context).
    if request_context and request_context.extra:
        open_preview_raw = request_context.extra.get("open_scripts_preview")
        if open_preview_raw and isinstance(open_preview_raw, list) and len(open_preview_raw) > 0:
            parts: List[str] = []
            for item in open_preview_raw[:5]:
                if isinstance(item, dict):
                    path_val = item.get("path") or item.get("path_str") or ""
                    prev = item.get("preview") or ""
                    if path_val or prev:
                        parts.append(f"--- Open in editor: {path_val} (first 24 lines) ---\n{prev}")
            if parts:
                optional_extras.append(
                    "Scripts currently open in the Godot Script Editor (user's project; res:// paths; first 24 lines each). "
                    "Call read_file(path) for full content before editing.\n\n"
                    + "\n\n".join(parts)
                )
    # User-dragged context: files/nodes dropped into the chat (FileSystem, Scene tree, Script list).
    extra = (request_context.extra or {}) if request_context else {}
    pinned_context_note = extra.get("pinned_context_note")
    drag_intro = (
        str(pinned_context_note).strip()
        if pinned_context_note
        else "The user just dragged these items into context for this chat. Prioritize them when answering."
    )
    if request_context and request_context.extra:
        pinned_files_raw = request_context.extra.get("pinned_files")
        if pinned_files_raw and isinstance(pinned_files_raw, list) and len(pinned_files_raw) > 0:
            parts = []
            for item in pinned_files_raw[:12]:
                if isinstance(item, dict):
                    path_val = (item.get("path") or item.get("path_str") or "").strip()
                    content = (item.get("content") or "").strip()
                    if path_val or content:
                        parts.append(f"--- Pinned file (user-dragged): {path_val} ---\n{content or '(empty)'}")
            if parts:
                optional_extras.append(drag_intro + "\n\nPinned files:\n\n" + "\n\n".join(parts))
        pinned_nodes_raw = request_context.extra.get("pinned_nodes")
        if pinned_nodes_raw and isinstance(pinned_nodes_raw, list) and len(pinned_nodes_raw) > 0:
            parts = []
            for item in pinned_nodes_raw[:20]:
                if isinstance(item, dict):
                    desc = (item.get("description") or "").strip()
                    scene_path = (item.get("scene_path") or "").strip()
                    node_path = (item.get("node_path") or "").strip()
                    if desc or node_path:
                        line = desc or f"Node path: {node_path}"
                        if scene_path and not (item.get("is_scene_root")):
                            line += f" (scene: {scene_path})"
                        parts.append(line)
            if parts:
                optional_extras.append(drag_intro + "\n\nPinned nodes/scene:\n\n" + "\n".join(parts))
    if is_obscure:
        optional_extras.append(
            "Heuristic: This seems like an obscure area; consider lower-importance snippets too."
        )
    # When fixing lint or user asks to fix a file: inject GDScript 4 rules so the model fixes common parse errors correctly.
    if (errors_text and str(errors_text).strip()) or ("fix" in question.lower() or "lint" in question.lower()):
        gd4_rules = (
            "GDScript 4.x lint fix rules (apply when fixing .gd files):\n"
            "- 'Expected type specifier after \"is\"': Use == null or != null for null checks, not 'is null'. "
            "The 'is' keyword is only for type checks (e.g. if x is Node2D). Replace 'if x is null' with 'if x == null' and 'if x is not null' with 'if x != null'.\n"
            "- 'Member \"velocity\" redefined': CharacterBody2D/CharacterBody3D already have a built-in 'velocity' property. Remove the duplicate 'var velocity: Vector2 = ...' or 'var velocity: Vector3 = ...' declaration; use the built-in property.\n"
            "- 'Too many arguments for move_and_slide()': In Godot 4, move_and_slide() takes no arguments. Set the node's 'velocity' property, then call move_and_slide() with no args. Do not assign the return value to velocity (it returns a bool).\n"
            "- 'Assignment is not allowed inside an expression': You cannot assign and use in the same expression; split into two statements or fix the invalid syntax."
        )
        optional_extras.append(gd4_rules)
    # Repair memory: if lint/errors are present, retrieve past fixes for the same normalized signature.
    if errors_text and engine_version:
        try:
            fixes = search_lint_fixes(
                engine_version=str(engine_version),
                raw_lint_output=str(errors_text),
                limit=3,
            )
            block = format_fixes_for_prompt(fixes)
            if block:
                optional_extras.append(block)
        except Exception:
            pass

    # Component/class context: when the user has a node type selected, inject its docs so the LLM knows properties for modify_attribute.
    # Include base class docs for custom/obscure types (e.g. class_name Player extends CharacterBody2D -> also fetch CharacterBody2D docs).
    selected_node_base_type: Optional[str] = None
    if request_context and request_context.extra:
        selected_node_base_type = (request_context.extra.get("selected_node_base_type") or "").strip() or None
    types_to_doc: List[str] = []
    if selected_node_type:
        types_to_doc.append(selected_node_type)
    if selected_node_base_type and selected_node_base_type != selected_node_type:
        types_to_doc.append(selected_node_base_type)
    for node_type_name in types_to_doc:
        try:
            class_docs = _collect_top_docs(
                f"{node_type_name} class properties methods documentation",
                top_k=2,
            )
            if class_docs:
                class_parts = [
                    f"[DOC] path={d.source_path}\n{d.text_preview}"
                    for d in class_docs
                ]
                optional_extras.append(
                    f"Documentation for node type ({node_type_name}), use for modify_attribute(target_type='node', ...):\n"
                    + "\n\n".join(class_parts)
                )
        except Exception:
            pass

    # Extends to fetch: from question, scene root, active file, and current scene scripts (aggressive matching).
    extends_to_fetch: List[str] = []
    q_lower = question.lower().strip()
    for cls in ("CharacterBody3D", "CharacterBody2D", "Camera3D", "Camera2D", "Node3D", "Node2D", "RigidBody3D"):
        if cls.lower() in q_lower:
            extends_to_fetch.append(cls)
    if not any(c in extends_to_fetch for c in ("CharacterBody3D", "CharacterBody2D")):
        if scene_dimension == "3d" or "3d" in q_lower or "first person" in q_lower or "fps" in q_lower:
            if "player" in q_lower or "character" in q_lower or "controller" in q_lower or "movement" in q_lower:
                extends_to_fetch.append("CharacterBody3D")
        if scene_dimension == "2d":
            if "player" in q_lower or "character" in q_lower or "controller" in q_lower or "movement" in q_lower:
                extends_to_fetch.append("CharacterBody2D")
    if "camera" in q_lower and "Camera3D" not in extends_to_fetch and "Camera2D" not in extends_to_fetch:
        extends_to_fetch.append("Camera3D" if (scene_dimension == "3d" or "3d" in q_lower) else "Camera2D")
    # From current project: active script and scene scripts (so we attach repo examples of same type).
    lang = "gdscript" if (context_language or "").strip().lower() != "csharp" else "csharp"
    if active_file_text and active_file_text.strip():
        ext = extract_extends_from_script(active_file_text, lang)
        if ext and ext not in extends_to_fetch:
            extends_to_fetch.append(ext)
    if scene_root_class and scene_root_class not in extends_to_fetch:
        extends_to_fetch.append(scene_root_class)
    for _path, content in current_scene_scripts:
        ext = extract_extends_from_script(content, lang)
        if ext and ext not in extends_to_fetch:
            extends_to_fetch.append(ext)
    extends_to_fetch = list(dict.fromkeys(extends_to_fetch))

    # Build component_scripts block (repo examples by type). Dropped first when context >50% full.
    component_scripts_parts = []
    for extends_class in extends_to_fetch:
        try:
            component_scripts = _collect_code_by_extends(extends_class, language=lang, max_scripts=2)
            block = format_component_scripts_block(extends_class, component_scripts)
            if block:
                component_scripts_parts.append(block)
        except Exception:
            pass
    component_scripts_text = "\n".join(component_scripts_parts) if component_scripts_parts else None

    blocks = build_ordered_blocks(
        model=model,
        system_instructions=system_prompt,
        question=question,
        active_file_path=active_file_path,
        active_file_text=active_file_text,
        errors_text=errors_text,
        retrieved_docs=retrieved_docs,
        retrieved_code=retrieved_code,
        related_files=related_files,
        recent_edits=recent_edits_text,
        optional_extras=optional_extras,
        include_system_in_user=False,
        environment_text=environment_text,
        current_scene_scripts=current_scene_scripts if current_scene_scripts else None,
        component_scripts_text=component_scripts_text,
        exclude_block_keys=exclude_block_keys,
    )
    limit = get_context_limit(model)
    # When context fills over 50%, drop lowest-priority blocks first (component_scripts, extras).
    user_content, _dbg = blocks_to_user_content(
        blocks, limit=limit, reserve=4096, fill_target_ratio=0.5
    )
    context_view_for_response = build_context_view(blocks, _dbg)
    # Verbose decision log for the context viewer UI.
    context_decision_log: List[str] = []
    context_decision_log.append(
        f"Context limit: {limit} tokens; reserve: 4096; target cap: 50% fill"
    )
    if component_types_from_path:
        context_decision_log.append(
            f"Active file path suggests component types: {', '.join(component_types_from_path)} → code retrieval biased to these examples"
        )
    context_decision_log.extend(_dbg.get("log", []))
    user_content += (
        "\n\n[AGENT MODE: When the user asks to fix or edit a file, you MUST call read_file(path) then apply_patch(path, old_string, new_string) or write_file(path, content). Do not only describe the fix.]\n"
        "You may call read_file(path) to read any project file; list_files(path, recursive, extensions) to find all files of a type (e.g. all .svg); "
        "read_import_options(path) to see import settings; modify_attribute(target_type='import', path=..., attribute=..., value=...) to change them (e.g. attribute=compress, value=true for lossless SVG). "
        "Use modify_attribute(target_type='node', scene_path=..., node_path=..., attribute=..., value=...) for node properties. "
        "For create_node: use the current scene (omit scene_path or pass 'current') and parent_path /root. Use 2D node types (Node2D, CharacterBody2D, Sprite2D) in 2D scenes and 3D types (Node3D, CharacterBody3D) in 3D scenes.\n"
        "To add a script to a node: create_script(path, extends_class, initial_content), then modify_attribute(target_type='node', scene_path=..., node_path=..., attribute='script', value='res://path/to/script.gd').\n"
        "For fixes/edits: read_file(path) first, then apply_patch(path, old_string, new_string) or write_file(path, content). You will receive written content in the tool result; do not call read_file to verify. "
        "In GDScript (.gd) files the first line is already 'extends ClassName'; when using write_file or apply_patch on a .gd file, do not add or duplicate an extends line—only one extends per script. "
        "If the existing context is enough, answer directly.\n"
    )

    messages: List[Dict[str, Any]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_content},
    ]

    tools_payload = get_openai_tools_payload()

    tool_call_results: List[ToolCallResult] = []
    total_prompt_tokens = 0
    total_completion_tokens = 0
    read_file_cache: Dict[str, str] = {}  # path -> content, per request

    for _ in range(max_tool_rounds):
        # Basic Stage-1 context budgeting: conservatively trim the user message content
        # so we never explode prompt size. (Compression/summarization comes later.)
        limit = get_context_limit(model)
        # Reserve space for the model's answer + tool chatter.
        budget_for_input = max(2048, limit - 4096)
        if messages and isinstance(messages[-1], dict) and "content" in messages[-1]:
            content = str(messages[-1].get("content") or "")
            if content:
                # Only trim if we are far over budget; this is a stub.
                # We use a cheap estimator; later we will rank+select context candidates.
                est = build_context_usage(
                    model,
                    [m.get("content", "") for m in messages if isinstance(m, dict)],
                ).estimated_prompt_tokens
                if est > budget_for_input:
                    messages[-1]["content"] = trim_text_to_tokens(content, max(1, budget_for_input - 512))

        # Debug: log the exact payload sent to the LLM.
        _log_llm_input(model=model, context="query_with_tools", input_payload=messages)

        response = client.responses.create(
            model=model,
            input=messages,
            tools=tools_payload,
        )

        # Accumulate usage if provided by the Responses API.
        usage = getattr(response, "usage", None)
        if usage is not None:
            # The Responses API may expose input/output or prompt/completion tokens;
            # try both naming schemes.
            prompt_tokens = (
                getattr(usage, "input_tokens", None)
                or getattr(usage, "prompt_tokens", None)
                or 0
            )
            completion_tokens = (
                getattr(usage, "output_tokens", None)
                or getattr(usage, "completion_tokens", None)
                or 0
            )
            total_prompt_tokens += int(prompt_tokens)
            total_completion_tokens += int(completion_tokens)

        # The Responses API may emit multiple output items (message + tool calls).
        outputs = getattr(response, "output", None) or []

        # Collect any tool calls in this turn across all output items.
        # Keep call_id so we can send function_call_output back to the Responses API.
        # Keep the raw tool-call item from the model so call_id matches exactly.
        parsed_tool_calls: List[Tuple[str, str, Dict[str, Any], Dict[str, Any]]] = []
        for out in outputs:
            out_type = getattr(out, "type", None) or (out.get("type") if isinstance(out, dict) else None)
            # Common shape: {type:"function_call", name:"...", arguments:"{...}"}
            if out_type in ("function_call", "tool_call"):
                name = getattr(out, "name", None) or (out.get("name") if isinstance(out, dict) else None)
                call_id = getattr(out, "call_id", None) or getattr(out, "id", None) or (out.get("call_id") if isinstance(out, dict) else None) or (out.get("id") if isinstance(out, dict) else None)
                args_raw = getattr(out, "arguments", None) or (out.get("arguments") if isinstance(out, dict) else None) or "{}"
                if name and call_id:
                    try:
                        args_dict = json.loads(args_raw) if isinstance(args_raw, str) else (args_raw or {})
                    except Exception:
                        args_dict = {}
                    if isinstance(out, dict):
                        call_item = out
                    else:
                        # Best-effort: preserve everything the SDK exposes.
                        try:
                            call_item = out.model_dump()  # type: ignore[attr-defined]
                        except Exception:
                            call_item = {
                                "type": "function_call",
                                "call_id": str(call_id),
                                "name": str(name),
                                "arguments": args_raw if isinstance(args_raw, str) else json.dumps(args_raw or {}),
                            }
                    parsed_tool_calls.append((str(name), str(call_id), args_dict, call_item))
                continue

            # Older/alternate client shape: output.tool_calls = [{type:"function", function:{name, arguments}}]
            tool_calls = getattr(out, "tool_calls", None) or []
            for tc in tool_calls:
                tc_type = getattr(tc, "type", None) or (tc.get("type") if isinstance(tc, dict) else None)
                if tc_type != "function":
                    continue
                fn = getattr(tc, "function", None) or (tc.get("function") if isinstance(tc, dict) else None) or {}
                name = getattr(fn, "name", None) or (fn.get("name") if isinstance(fn, dict) else None)
                args_raw = getattr(fn, "arguments", None) or (fn.get("arguments") if isinstance(fn, dict) else None) or "{}"
                # Some SDK versions include a tool_call id; fall back to a stable placeholder if missing.
                call_id = getattr(tc, "id", None) or (tc.get("id") if isinstance(tc, dict) else None) or f"{name}_call"
                if name and call_id:
                    try:
                        args_dict = json.loads(args_raw) if isinstance(args_raw, str) else (args_raw or {})
                    except Exception:
                        args_dict = {}
                    # We don't have the original Responses output item here; still provide a compatible item.
                    call_item = {
                        "type": "function_call",
                        "call_id": str(call_id),
                        "name": str(name),
                        "arguments": args_raw if isinstance(args_raw, str) else json.dumps(args_raw or {}),
                    }
                    parsed_tool_calls.append((str(name), str(call_id), args_dict, call_item))

        if parsed_tool_calls:
            for name, call_id, args_dict, call_item in parsed_tool_calls:
                # When we have project_root_abs (plugin sent it), run read_file / list_files /
                # read_import_options on the backend so the LLM receives the result. Otherwise
                # return execute_on_client payload for the plugin to run.
                if name == "read_file" and project_root_abs:
                    path = (args_dict.get("path") or "").strip()
                    if path:
                        cache_key = (path if path.startswith("res://") else "res://" + path.lstrip("/")).replace("\\", "/")
                        if cache_key in read_file_cache:
                            content = read_file_cache[cache_key]
                            tool_output = {
                                "success": True,
                                "path": path,
                                "content": content,
                                "message": "Read (cached): %s (%d chars)" % (path, len(content)),
                            }
                        else:
                            content = read_project_file(project_root_abs, path)
                            content_str = content or ""
                            read_file_cache[cache_key] = content_str
                            tool_output = {
                                "success": True,
                                "path": path,
                                "content": content_str,
                                "message": "Read: %s (%d chars)" % (path, len(content_str)),
                            }
                    else:
                        tool_output = dispatch_tool_call(name, args_dict)
                elif name == "list_files" and project_root_abs:
                    path = (args_dict.get("path") or "res://").strip() or "res://"
                    recursive = bool(args_dict.get("recursive", True))
                    extensions = args_dict.get("extensions") or []
                    max_entries = min(2000, max(1, int(args_dict.get("max_entries", 500))))
                    paths = list_project_files(
                        project_root_abs, path, recursive=recursive,
                        extensions=extensions, max_entries=max_entries,
                    )
                    tool_output = {
                        "success": True,
                        "message": "Listed %d file(s) under %s" % (len(paths), path),
                        "path": path,
                        "paths": paths,
                    }
                elif name == "read_import_options" and project_root_abs:
                    path = (args_dict.get("path") or "").strip()
                    if path:
                        import_path = path if path.endswith(".import") else path + ".import"
                        content = read_project_file(project_root_abs, import_path)
                        tool_output = {
                            "success": content is not None,
                            "message": "Read import options for %s" % path if content is not None else "No .import file found for: %s" % path,
                            "path": path,
                            "import_path": import_path,
                            "content": content or "",
                        }
                    else:
                        tool_output = dispatch_tool_call(name, args_dict)
                elif name == "list_directory" and project_root_abs:
                    path = (args_dict.get("path") or "res://").strip() or "res://"
                    recursive = bool(args_dict.get("recursive", False))
                    max_entries = min(2000, max(1, int(args_dict.get("max_entries", 250))))
                    max_depth = min(20, max(0, int(args_dict.get("max_depth", 6))))
                    entries = list_project_directory(
                        project_root_abs, path, recursive=recursive,
                        max_entries=max_entries, max_depth=max_depth,
                    )
                    tool_output = {
                        "success": True,
                        "message": "Listed %d entry/entries under %s" % (len(entries), path),
                        "path": path,
                        "entries": entries,
                    }
                elif name == "search_files" and project_root_abs:
                    query = (args_dict.get("query") or "").strip()
                    if not query:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        root_path = (args_dict.get("root_path") or "res://").strip() or "res://"
                        extensions = args_dict.get("extensions") or []
                        max_matches = min(500, max(1, int(args_dict.get("max_matches", 50))))
                        results = search_project_files(
                            project_root_abs, query, root_path=root_path,
                            extensions=extensions, max_matches=max_matches,
                        )
                        tool_output = {
                            "success": True,
                            "message": "Found %d file(s) containing %r" % (len(results), query),
                            "query": query,
                            "results": results,
                        }
                elif name == "project_structure" and project_root_abs:
                    prefix = (args_dict.get("prefix") or "res://").strip() or "res://"
                    max_paths = min(1000, max(1, int(args_dict.get("max_paths", 300))))
                    max_depth_arg = args_dict.get("max_depth")
                    max_depth = int(max_depth_arg) if max_depth_arg is not None else None
                    if max_depth is not None:
                        max_depth = min(10, max(1, max_depth))
                    paths = list_indexed_paths(
                        project_root_abs, prefix=prefix, max_paths=max_paths, max_depth=max_depth
                    )
                    tool_output = {
                        "success": True,
                        "message": "Listed %d path(s) under %s" % (len(paths), prefix),
                        "prefix": prefix,
                        "paths": paths,
                    }
                elif name == "find_scripts_by_extends" and project_root_abs:
                    extends_class = (args_dict.get("extends_class") or "").strip()
                    if not extends_class:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        query = "extends " + extends_class
                        results = search_project_files(
                            project_root_abs, query, root_path="res://",
                            extensions=[".gd", ".cs"], max_matches=30,
                        )
                        paths = [r["path"] for r in results]
                        tool_output = {
                            "success": True,
                            "message": "Found %d script(s) extending %s" % (len(paths), extends_class),
                            "extends_class": extends_class,
                            "paths": paths,
                        }
                elif name == "find_references_to" and project_root_abs:
                    res_path = (args_dict.get("res_path") or "").strip()
                    if not res_path:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        refs = get_inbound_refs(project_root_abs, res_path, limit=20)
                        tool_output = {
                            "success": True,
                            "message": "Found %d file(s) referencing %s" % (len(refs), res_path),
                            "res_path": res_path,
                            "references": refs,
                        }
                elif name == "create_file" and project_root_abs:
                    path = (args_dict.get("path") or "").strip()
                    if not path:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        content = args_dict.get("content", "") or ""
                        overwrite = bool(args_dict.get("overwrite", False))
                        tool_output = write_project_file(
                            project_root_abs, path, content, overwrite=overwrite
                        )
                elif name == "write_file" and project_root_abs:
                    path = (args_dict.get("path") or "").strip()
                    if not path:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        content = args_dict.get("content", "") or ""
                        tool_output = write_project_file(
                            project_root_abs, path, content, overwrite=True
                        )
                elif name == "apply_patch" and project_root_abs:
                    path = (args_dict.get("path") or "").strip()
                    if not path:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        diff_text = (args_dict.get("diff") or "").strip()
                        if diff_text:
                            tool_output = apply_project_patch_unified(
                                project_root_abs, path, diff_text
                            )
                        else:
                            old_string = args_dict.get("old_string", "") or ""
                            new_string = args_dict.get("new_string", "") or ""
                            tool_output = apply_project_patch(
                                project_root_abs, path, old_string, new_string
                            )
                elif name == "append_to_file" and project_root_abs:
                    path = (args_dict.get("path") or "").strip()
                    if not path:
                        tool_output = dispatch_tool_call(name, args_dict)
                    else:
                        content = args_dict.get("content", "") or ""
                        tool_output = append_project_file(project_root_abs, path, content)
                elif name == "create_node":
                    # Default to current open scene so nodes are always attached; LLM often omits scene_path.
                    sp = (args_dict.get("scene_path") or "").strip()
                    if not sp or sp.lower() == "current":
                        args_dict = {**args_dict, "scene_path": active_scene_path or "current"}
                    tool_output = dispatch_tool_call(name, args_dict)
                else:
                    tool_output = dispatch_tool_call(name, args_dict)
                tool_call_results.append(
                    ToolCallResult(tool_name=name, arguments=args_dict, output=tool_output)
                )

                # Feed tool result back to the Responses API.
                # See: function_call_output items.
                messages.append(call_item)
                messages.append(
                    {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": json.dumps(tool_output),
                    }
                )
            continue

        # No tool calls → expect final natural-language answer.
        # Prefer response.output_text if available; otherwise parse message content.
        answer = getattr(response, "output_text", None) or ""
        if not answer:
            for out in outputs:
                out_type = getattr(out, "type", None) or (out.get("type") if isinstance(out, dict) else None)
                if out_type != "message":
                    continue
                msg = getattr(out, "message", None) or (out.get("message") if isinstance(out, dict) else None) or {}
                final_content = msg.get("content") if isinstance(msg, dict) else getattr(msg, "content", "")
                if isinstance(final_content, list):
                    text_parts = [
                        part.get("text", "") if isinstance(part, dict) else str(part)
                        for part in final_content
                    ]
                    answer = "".join(text_parts)
                else:
                    answer = str(final_content or "")
                break

        if answer:
            snippets = docs + code_snippets
            usage_obj = build_context_usage(
                model,
                [m.get("content", "") for m in messages if isinstance(m, dict) and "content" in m],
            )
            if total_prompt_tokens or total_completion_tokens:
                _log_usage_and_cost(
                    model=model,
                    prompt_tokens=total_prompt_tokens,
                    completion_tokens=total_completion_tokens,
                    context="query_with_tools",
                )
                record_usage(model, total_prompt_tokens, total_completion_tokens)
            # attach estimated usage (UI uses this)
            usage_obj = build_context_usage(
                model,
                [m.get("content", "") for m in messages if isinstance(m, dict) and "content" in m],
            )
            return answer, snippets, tool_call_results, {
                "model": usage_obj.model,
                "limit_tokens": usage_obj.limit_tokens,
                "estimated_prompt_tokens": usage_obj.estimated_prompt_tokens,
                "percent": usage_obj.percent,
                "context_view": context_view_for_response,
                "context_decision_log": context_decision_log,
            }

        # Fallback: no tool calls and no message; break.
        break

    # If we exit the loop without a clean final answer, fall back to the
    # existing RAG-only answer builder.
    fallback_answer = _call_llm_with_rag(
        question=question,
        context_language=context_language,
        docs=docs,
        code_snippets=code_snippets,
        is_obscure=is_obscure,
        client=client,
        model=model,
    )
    if total_prompt_tokens or total_completion_tokens:
        _log_usage_and_cost(
            model=model,
            prompt_tokens=total_prompt_tokens,
            completion_tokens=total_completion_tokens,
            context="query_with_tools_fallback",
        )
        record_usage(model, total_prompt_tokens, total_completion_tokens)
    usage_obj = build_context_usage(model, [question])
    return fallback_answer, docs + code_snippets, tool_call_results, {
        "model": usage_obj.model,
        "limit_tokens": usage_obj.limit_tokens,
        "estimated_prompt_tokens": usage_obj.estimated_prompt_tokens,
        "percent": usage_obj.percent,
        "context_view": context_view_for_response,
        "context_decision_log": context_decision_log,
    }


@app.get("/health")
async def health() -> Dict[str, str]:
    """
    Simple health check so the Godot plugin can verify connectivity.
    """
    return {"status": "ok"}


class IndexStatusResponse(BaseModel):
    chroma_docs: int = 0
    chroma_project_code: int = 0
    repo_index_error: Optional[str] = None
    repo_index_files: Optional[int] = None
    repo_index_edges: Optional[int] = None


@app.get("/index_status", response_model=IndexStatusResponse)
async def index_status(project_root: Optional[str] = None) -> IndexStatusResponse:
    """
    Return indexing facts: Chroma collection counts and optional repo index stats.
    If project_root is provided (query param), also return repo index file/edge counts.
    """
    docs_c, code_c = get_collections()
    chroma_docs = int(docs_c.count()) if docs_c is not None else 0
    chroma_project_code = int(code_c.count()) if code_c is not None else 0
    out = IndexStatusResponse(
        chroma_docs=chroma_docs,
        chroma_project_code=chroma_project_code,
    )
    if project_root and project_root.strip():
        root = project_root.strip()
        stats = get_repo_index_stats(root)
        if "error" in stats:
            out.repo_index_error = str(stats["error"])
        else:
            out.repo_index_files = stats.get("files", 0)
            out.repo_index_edges = stats.get("edges", 0)
    return out


class FileChangeIn(BaseModel):
    file_path: str
    change_type: str = "modify"
    old_content: str = ""
    new_content: str = ""


class EditEventIn(BaseModel):
    actor: str = "ai"
    trigger: str = "tool_action"
    summary: str
    prompt: Optional[str] = None
    changes: List[FileChangeIn]
    semantic_summary: Optional[str] = None
    lint_errors_before: Optional[str] = None
    lint_errors_after: Optional[str] = None
    retrieved_chunk_ids: Optional[List[str]] = None


class UndoResponse(BaseModel):
    tool_calls: List[ToolCallResult] = []


class LintFixIn(BaseModel):
    project_root_abs: str
    file_path: str  # res://...
    engine_version: str
    raw_lint_output: str
    old_content: str
    new_content: str
    prompt: Optional[str] = None


@app.post("/lint_memory/record_fix")
async def lint_memory_record_fix(payload: LintFixIn) -> Dict[str, Any]:
    # Explanation: best-effort. If no LLM, store a simple fallback.
    model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")
    client = get_openai_client()
    explanation = "Recorded diff that resolved this lint output."

    if client is not None:
        try:
            # Keep this prompt short; it is internal only.
            prompt = (
                "You are summarizing a fix that resolved a Godot linter failure.\n"
                f"Engine: {payload.engine_version}\n"
                f"File: {payload.file_path}\n"
                "Lint output:\n"
                f"{payload.raw_lint_output}\n\n"
                "Describe in 1-2 sentences what changed and the rule it implies, focusing on Godot 4.x GDScript correctness."
            )
            completion = client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": "Be concise and specific. No fluff."},
                    {"role": "user", "content": prompt},
                ],
            )
            explanation = (completion.choices[0].message.content or "").strip() or explanation
        except Exception:
            pass

    rec = create_lint_fix_record(
        project_root_abs=payload.project_root_abs,
        file_path=payload.file_path,
        engine_version=payload.engine_version,
        raw_lint_output=payload.raw_lint_output,
        old_content=payload.old_content,
        new_content=payload.new_content,
        explanation=explanation,
        model=model if client is not None else None,
    )
    return {"ok": True, "record": rec}


@app.get("/lint_memory/search")
async def lint_memory_search(engine_version: str, raw_lint_output: str, limit: int = 3) -> Dict[str, Any]:
    results = search_lint_fixes(
        engine_version=str(engine_version),
        raw_lint_output=str(raw_lint_output),
        limit=int(limit),
    )
    return {"ok": True, "results": results}


class LintRequest(BaseModel):
    """Request to run Godot script linter on a file. Run from backend to avoid spawning Godot from inside the editor (which can crash)."""
    project_root_abs: str
    path: str  # res://path or path relative to project


def _get_godot_bin() -> str:
    """Godot executable for headless lint. Prefer GODOT_BIN env; else 'godot' (or godot.exe on Windows)."""
    bin_path = os.getenv("GODOT_BIN", "").strip()
    if bin_path:
        return bin_path
    if sys.platform == "win32":
        return "godot.exe"
    return "godot"


# Timeout for headless Godot lint (prevents hang/crash from infinite loops or slow load).
_LINT_SUBPROCESS_TIMEOUT_SECONDS = 60.0

# Cache for /lint: (project_root, path, mtime) -> (result, timestamp). TTL in seconds.
_LINT_CACHE_TTL_SECONDS = 10.0
_lint_cache: dict[tuple[str, str, float], tuple[Dict[str, Any], float]] = {}


def _lint_cache_key(project_root: str, path: str) -> tuple[str, str, float]:
    """Key is (project_root, path, mtime). mtime=0 if file missing."""
    abs_path = os.path.join(project_root, path)
    mtime = 0.0
    if os.path.isfile(abs_path):
        mtime = os.path.getmtime(abs_path)
    return (project_root, path, mtime)


@app.post("/lint")
async def run_lint(payload: LintRequest) -> Dict[str, Any]:
    """
    Run Godot headless linter (--script path --check-only) on a script file.
    Uses the same parser as the editor so errors match what the user sees.
    Called by the plugin so the editor never spawns a second Godot process (which can crash).
    Do not use --debug: it can cause infinite loops when the script has parser errors.
    Results are cached by (project_root, path, mtime) for 10s to avoid redundant Godot spawns.
    """
    project_root = (payload.project_root_abs or "").strip().rstrip("/\\")
    path = (payload.path or "").strip().replace("\\", "/")
    if path.startswith("res://"):
        path = path[6:].lstrip("/")
    if not project_root or not path:
        return {"success": False, "output": "project_root_abs and path are required", "exit_code": -1}
    if not os.path.isdir(project_root):
        return {"success": False, "output": f"Project root not found: {project_root}", "exit_code": -1}
    now = time.monotonic()
    cache_key = _lint_cache_key(project_root, path)
    if cache_key in _lint_cache:
        cached_result, cached_at = _lint_cache[cache_key]
        if (now - cached_at) < _LINT_CACHE_TTL_SECONDS:
            return cached_result
        del _lint_cache[cache_key]
    godot_bin = _get_godot_bin()
    # Godot docs: --check-only must be used with --script. Path is relative to project (res://).
    # --editor loads the project for full type checking; --headless avoids GUI. No --debug (can hang on errors).
    args = [godot_bin, "--headless", "--editor", "--path", project_root, "--script", path, "--check-only"]
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=project_root,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=_LINT_SUBPROCESS_TIMEOUT_SECONDS
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return {
                "success": False,
                "output": f"Lint timed out after {int(_LINT_SUBPROCESS_TIMEOUT_SECONDS)}s. Godot may have hung (try simplifying the script or set GODOT_BIN to a stable build).",
                "exit_code": -1,
            }
        out = (stdout_bytes or b"").decode("utf-8", errors="replace") + (stderr_bytes or b"").decode("utf-8", errors="replace")
        out = out.strip()
        result = {"success": proc.returncode == 0, "output": out, "exit_code": proc.returncode or 0}
        _lint_cache[cache_key] = (result, now)
        return result
    except FileNotFoundError:
        return {
            "success": False,
            "output": f"Godot not found: {godot_bin}. Set GODOT_BIN to the full path to the Godot editor executable.",
            "exit_code": -1,
        }
    except Exception as e:
        return {"success": False, "output": str(e), "exit_code": -1}


@app.post("/edit_events/create")
async def edit_events_create(payload: EditEventIn) -> Dict[str, Any]:
    edit_id = create_edit_event(
        actor=payload.actor,
        trigger=payload.trigger,
        summary=payload.summary,
        prompt=payload.prompt,
        changes=[c.model_dump() for c in payload.changes],
        semantic_summary=payload.semantic_summary,
        lint_errors_before=payload.lint_errors_before,
        lint_errors_after=payload.lint_errors_after,
        retrieved_chunk_ids=payload.retrieved_chunk_ids,
    )
    return {"ok": True, "edit_id": edit_id}


@app.get("/edit_events/list")
async def edit_events_list(limit: int = 500) -> Dict[str, Any]:
    return {"ok": True, "events": list_edit_events(limit=int(limit))}


@app.get("/usage")
async def usage() -> Dict[str, Any]:
    """
    Return aggregated token usage and estimated cost (from usage_log).
    Used by the Edit History tab to show tokens and cost at the bottom.
    """
    totals = get_usage_totals()
    cost_usd = 0.0
    by_model = totals.get("by_model") or {}
    for model, counts in by_model.items():
        cost_usd += _estimate_cost_usd(
            model,
            counts.get("prompt_tokens", 0),
            counts.get("completion_tokens", 0),
        )
    return {
        "ok": True,
        "total_prompt_tokens": totals.get("total_prompt_tokens", 0),
        "total_completion_tokens": totals.get("total_completion_tokens", 0),
        "total_tokens": totals.get("total_prompt_tokens", 0) + totals.get("total_completion_tokens", 0),
        "estimated_cost_usd": round(cost_usd, 4),
        "by_model": by_model,
    }


@app.get("/edit_events/{edit_id}")
async def edit_events_get(edit_id: int) -> Dict[str, Any]:
    e = get_edit_event(int(edit_id))
    if not e:
        return {"ok": False, "error": "not_found"}
    return {"ok": True, "event": e}


@app.post("/edit_events/undo/{edit_id}", response_model=UndoResponse)
async def edit_events_undo(edit_id: int) -> UndoResponse:
    e = get_edit_event(int(edit_id))
    if not e:
        return UndoResponse(tool_calls=[])

    tool_calls: List[ToolCallResult] = []
    for ch in e.get("changes", []):
        path = ch.get("file_path", "")
        old_content = ch.get("old_content", "") or ""
        if not path:
            continue
        # Undo by restoring previous content.
        tool_output = {"execute_on_client": True, "action": "write_file", "path": path, "content": old_content}
        tool_calls.append(
            ToolCallResult(
                tool_name="write_file",
                arguments={"path": path, "content": old_content},
                output=tool_output,
            )
        )

    return UndoResponse(tool_calls=tool_calls)


@app.post("/query", response_model=QueryResponseWithTools)
async def query_rag(payload: QueryRequest, request: Request) -> QueryResponseWithTools:
    """
    RAG endpoint that:
    - Searches Godot docs (if indexed) in ChromaDB.
    - Searches project code in ChromaDB, preferring higher-importance snippets.
    - Expands to lower-importance code if the area looks more obscure
      (i.e. we don't find enough high-tier hits).
    """
    client_host = request.client.host if request.client else "unknown"
    _log_rag_request("POST /query", client_host, payload.question or "", _cyan)

    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    answer, snippets, tool_calls, context_usage = _run_query_with_tools(
        question=question,
        context_language=context_language,
        request_context=payload.context,
        top_k=payload.top_k,
        max_tool_rounds=payload.max_tool_rounds if payload.max_tool_rounds is not None else 5,
        api_key=payload.api_key,
        base_url=payload.base_url,
        model_override=payload.model,
    )

    return QueryResponseWithTools(
        answer=answer,
        snippets=snippets,
        tool_calls=tool_calls,
        context_usage=context_usage,
    )


# Sentinel line the plugin uses to parse tool_calls from the stream.
_STREAM_TOOL_CALLS_PREFIX = "\n__TOOL_CALLS__\n"


@app.post("/query_stream_with_tools")
async def query_stream_with_tools(payload: QueryRequest, request: Request):
    """
    Same as /query (RAG + tools) but streams the answer in chunks, then appends
    a line __TOOL_CALLS__\\n + JSON array of tool_calls. Use when editor actions
    are enabled so the user sees progressive output and still gets tool execution.
    """
    client_host = request.client.host if request.client else "unknown"
    _log_rag_request("POST /query_stream_with_tools", client_host, payload.question or "", _green)

    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    def run():
        return _run_query_with_tools(
            question=question,
            context_language=context_language,
            request_context=payload.context,
            top_k=payload.top_k,
            max_tool_rounds=payload.max_tool_rounds if payload.max_tool_rounds is not None else 5,
            api_key=payload.api_key,
            base_url=payload.base_url,
            model_override=payload.model,
        )

    answer, snippets, tool_calls, context_usage = await asyncio.to_thread(run)

    def stream_iter():
        # Stream answer in small chunks so UI updates progressively.
        chunk_size = 80
        for i in range(0, len(answer), chunk_size):
            yield answer[i : i + chunk_size]
        # Then send tool_calls so the client can run editor actions.
        payload_list = [tc.model_dump() for tc in tool_calls]
        yield _STREAM_TOOL_CALLS_PREFIX + json.dumps(payload_list) + "\n"
        yield "\n__USAGE__\n" + json.dumps(context_usage) + "\n"

    return StreamingResponse(
        stream_iter(), media_type="text/plain; charset=utf-8"
    )


@app.post("/query_stream")
async def query_stream(payload: QueryRequest, request: Request):
    """
    Streaming variant of /query.

    - Reuses the same RAG retrieval to build initial context.
    - If an OpenAI client is available, streams the answer text incrementally
      using chat completions in streaming mode.
    - If no OpenAI client is configured, streams a single fallback answer.
    """
    client_host = request.client.host if request.client else "unknown"
    _log_rag_request("POST /query_stream", client_host, payload.question or "", _dim)

    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    docs = _collect_top_docs(question, top_k=payload.top_k)
    code_snippets = _collect_code_results(
        question=question,
        language=context_language,
        top_k=payload.top_k,
    )
    is_obscure = len(code_snippets) < max(1, payload.top_k // 3)

    client, model = _openai_client_and_model(
        api_key=payload.api_key,
        base_url=payload.base_url,
        model=payload.model,
    )

    # Build the same structured context we use in _call_llm_with_rag.
    docs_block_lines: List[str] = []
    for d in docs:
        docs_block_lines.append(
            "Official docs snippet from the Godot 4.x manual:\n"
            f"[DOC] path={d.source_path} meta={d.metadata}\n{d.text_preview}\n"
        )
    code_block_lines: List[str] = []
    for s in code_snippets:
        code_block_lines.append(
            "Example project code snippet (not canonical API, use as inspiration only):\n"
            f"[CODE] path={s.source_path} meta={s.metadata}\n{s.text_preview}\n"
        )

    system_prompt = (
        "You are a Godot 4.x development assistant. "
        "You receive a user question plus retrieved documentation and real project code. "
        "The 'docs' collection is scraped from the official Godot manuals and is the "
        "authoritative source for engine behavior and APIs. The 'project_code' collection "
        "contains example scripts and shaders from a wide range of different open-source repos "
        "(not the user's project); they may reference project-specific types, addons, or paths. "
        "Treat them only as patterns and inspiration, not as canonical definitions or as code from the user's project. "
        "Use ONLY the provided context to answer. Prefer documentation when there is any "
        "conflict between docs and project code. Prefer higher-importance code snippets "
        "when multiple examples are relevant, but you may also rely on lower-importance "
        "snippets if the topic appears niche or under-documented. "
        "When writing code examples, default to the user's preferred language if given."
    )

    user_prompt_lines: List[str] = []
    user_prompt_lines.append(f"Question: {question}\n")
    if context_language:
        user_prompt_lines.append(f"Preferred language: {context_language}\n")
    if is_obscure:
        user_prompt_lines.append(
            "Heuristic: This seems like a more obscure area of the codebase; "
            "lower-importance snippets may also be relevant.\n"
        )
    if docs_block_lines:
        user_prompt_lines.append("\n=== Documentation Context ===\n")
        user_prompt_lines.extend(docs_block_lines)
    if code_block_lines:
        user_prompt_lines.append("\n=== Project Code Context ===\n")
        user_prompt_lines.extend(code_block_lines)
    user_prompt_lines.append(
        "\nPlease stream back your final answer text. It should already include any "
        "reasoning and code examples as appropriate.\n"
    )

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": "\n".join(user_prompt_lines)},
    ]

    _log_llm_input(model=model, context="query_stream", input_payload=messages)

    if client is None:
        def fallback_iter():
            text = _call_llm_with_rag(
                question=question,
                context_language=context_language,
                docs=docs,
                code_snippets=code_snippets,
                is_obscure=is_obscure,
                client=client,
                model=model,
            )
            yield text

        return StreamingResponse(fallback_iter(), media_type="text/plain; charset=utf-8")

    def stream_iter():
        stream = client.chat.completions.create(
            model=model,
            messages=messages,
            stream=True,
        )
        prompt_tokens = 0
        completion_tokens = 0
        for chunk in stream:
            try:
                delta = chunk.choices[0].delta.content or ""
            except Exception:
                delta = ""
            if delta:
                yield delta
            # Capture usage information from the final chunk if present.
            try:
                usage = getattr(chunk, "usage", None)
                if usage is not None:
                    prompt_tokens = getattr(usage, "prompt_tokens", 0) or prompt_tokens
                    completion_tokens = (
                        getattr(usage, "completion_tokens", 0) or completion_tokens
                    )
            except Exception:
                pass

        if prompt_tokens or completion_tokens:
            _log_usage_and_cost(
                model=model,
                prompt_tokens=int(prompt_tokens),
                completion_tokens=int(completion_tokens),
                context="query_stream",
            )
            record_usage(model, int(prompt_tokens), int(completion_tokens))

    return StreamingResponse(stream_iter(), media_type="text/plain; charset=utf-8")


if __name__ == "__main__":
    import uvicorn

    try:
        uvicorn.run(
            "app.main:app",
            host="0.0.0.0",
            port=8000,
            reload=True,
            log_level="warning",
        )
    except (KeyboardInterrupt, asyncio.CancelledError):
        sys.exit(0)

