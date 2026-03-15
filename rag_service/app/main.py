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
from .services.agent_deps import GodotQueryDeps
from .services.godot_agent import create_godot_agent
from .tools import (
    dispatch_tool_call,
    get_openai_tools_payload,
    get_registered_tools,
)
from .db import (
    create_edit_event,
    create_lint_fix_record,
    format_fixes_for_prompt,
    get_edit_event,
    get_usage_totals,
    init_db,
    list_edit_events,
    list_recent_file_changes,
    record_usage,
    search_lint_fixes,
)
from .services.context.context_builder import (
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
    grep_project_files,
    list_project_directory,
    read_project_godot_ini,
    search_project_files,
    write_project_file,
)
from .services.context.viewer import build_context_view
from .services.context.openviking_context import (
    add_turn_and_commit as openviking_add_turn_and_commit,
    ensure_openviking_data_dir,
    find_memories as openviking_find_memories,
)
from .services.console_service import dim as _dim, cyan as _cyan, green as _green, yellow as _yellow


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
        ensure_openviking_data_dir()
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


def _parse_composer_response(content: str) -> Tuple[str, List[Dict[str, Any]]]:
    """
    Parse Godot Composer (fine-tuned) model output. Expects optional text plus an optional
    JSON array of tool_calls at the end: [{"name": "...", "arguments": {...}}, ...].
    Returns (answer_text, list of {"name", "arguments"} dicts).
    """
    content = (content or "").strip()
    if not content:
        return "", []

    # Find the last line or block that looks like a JSON array of tool calls.
    tool_calls: List[Dict[str, Any]] = []
    answer = content
    # Try to find a JSON array in the content (often at the end after a newline).
    for start in range(len(content) - 1, -1, -1):
        if content[start] != "[":
            continue
        try:
            parsed = json.loads(content[start:])
            if isinstance(parsed, list) and len(parsed) > 0:
                if all(
                    isinstance(t, dict) and "name" in t and isinstance(t.get("arguments"), (dict, type(None)))
                    for t in parsed
                ):
                    tool_calls = [
                        {"name": str(t["name"]), "arguments": t.get("arguments") or {}}
                        for t in parsed
                    ]
                    answer = content[:start].strip()
                    break
        except (json.JSONDecodeError, TypeError):
            pass
    return answer, tool_calls


def _extract_tool_calls_from_pydantic_result(result: Any) -> List[ToolCallResult]:
    """
    Build List[ToolCallResult] from a Pydantic AI run result by walking all_messages()
    and pairing ToolCallPart with ToolReturnPart in order.
    """
    out: List[ToolCallResult] = []
    try:
        messages = result.all_messages()
    except Exception:
        return out
    call_parts: List[Tuple[str, Dict[str, Any]]] = []  # (tool_name, args)
    return_contents: List[Any] = []  # output per tool
    for msg in messages:
        parts = getattr(msg, "parts", [])
        for part in parts:
            pname = type(part).__name__
            if pname == "ToolCallPart":
                name = getattr(part, "tool_name", None)
                args = getattr(part, "args", None)
                if name is not None:
                    call_parts.append((str(name), args if isinstance(args, dict) else {}))
            elif pname == "ToolReturnPart":
                content = getattr(part, "content", None)
                return_contents.append(content)
    for i, (name, args) in enumerate(call_parts):
        output = return_contents[i] if i < len(return_contents) else None
        out.append(ToolCallResult(tool_name=name, arguments=args, output=output))
    return out


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
    # (Agent system instructions live in godot_agent.GODOT_AGENT_SYSTEM_PROMPT.)

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
        extra = {}
        project_root_abs = None
        engine_version = None
        exclude_block_keys = []

    chat_id: Optional[str] = (extra or {}).get("chat_id") if isinstance((extra or {}).get("chat_id"), str) else None

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

    # OpenViking: retrieve session memories for this chat (when chat_id present).
    retrieved_memories: List[str] = []
    if chat_id:
        try:
            mems = openviking_find_memories(chat_id, question, top_k=5)
            for m in mems:
                text = (m.get("overview") or m.get("content") or m.get("abstract") or "").strip()
                if text:
                    retrieved_memories.append(text)
        except Exception:
            pass

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
        retrieved_memories=retrieved_memories if retrieved_memories else None,
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

    # Pydantic AI agent: single run with tools; tool execution via execute_tool (tool_runner).
    read_file_cache: Dict[str, str] = {}
    deps = GodotQueryDeps(
        project_root_abs=project_root_abs,
        active_scene_path=active_scene_path,
        active_file_path=active_file_path,
        extra=(request_context.extra or {}) if request_context else {},
        read_file_cache=read_file_cache,
    )
    agent = create_godot_agent(model=model_override or model)
    result = agent.run_sync(user_content, deps=deps)
    tool_call_results = _extract_tool_calls_from_pydantic_result(result)
    answer = (result.output or "").strip()
    usage_obj = build_context_usage(
        model,
        [user_content],
    )
    run_usage = getattr(result, "usage", None)
    if run_usage is not None:
        total_prompt_tokens = getattr(run_usage, "input_tokens", None) or getattr(run_usage, "prompt_tokens", 0) or 0
        total_completion_tokens = getattr(run_usage, "output_tokens", None) or getattr(run_usage, "completion_tokens", 0) or 0
        if total_prompt_tokens or total_completion_tokens:
            _log_usage_and_cost(
                model=model,
                prompt_tokens=int(total_prompt_tokens),
                completion_tokens=int(total_completion_tokens),
                context="query_with_tools",
            )
            record_usage(model, int(total_prompt_tokens), int(total_completion_tokens))
    # OpenViking: commit this turn for memory extraction (fire-and-forget).
    if chat_id and answer:
        try:
            openviking_add_turn_and_commit(
                chat_id,
                [
                    {"role": "user", "content": question},
                    {"role": "assistant", "content": answer},
                ],
            )
        except Exception:
            pass
    return answer, docs + code_snippets, tool_call_results, {
        "model": usage_obj.model,
        "limit_tokens": usage_obj.limit_tokens,
        "estimated_prompt_tokens": usage_obj.estimated_prompt_tokens,
        "percent": usage_obj.percent,
        "context_view": context_view_for_response,
        "context_decision_log": context_decision_log,
    }


def _run_composer_query(
    question: str,
    context_language: Optional[str],
    request_context: Optional["QueryContext"],
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    model_override: Optional[str] = None,
) -> Tuple[str, List[SourceChunk], List[ToolCallResult], Dict[str, Any]]:
    """
    Godot Composer: single-turn call to a fine-tuned model that outputs tool_calls
    directly (no RAG, no tool loop). Uses same payload as /query; returns same shape.
    Model response is parsed for a JSON array of {name, arguments} at the end of content.
    """
    client, model = _openai_client_and_model(
        api_key=api_key, base_url=base_url, model=model_override
    )
    if client is None:
        return (
            "No Composer model configured. Set API key and model (e.g. godot-composer) in settings.",
            [],
            [],
            {"model": "", "limit_tokens": 0, "estimated_prompt_tokens": 0, "percent": 0.0},
        )

    extra = (request_context.extra or {}) if request_context else {}
    system_prompt = (
        "You are a Godot assistant. Use the available tools when needed. "
        "When you need to perform an action, respond with optional text and a JSON array of tool calls on one line: "
        '[{"name": "tool_name", "arguments": {...}}, ...]. Use res:// paths for Godot project files.'
    )
    user_parts: List[str] = [question]
    if extra.get("active_file_text"):
        user_parts.append("Current file content:\n" + str(extra["active_file_text"]))
    if extra.get("scene_tree"):
        user_parts.append("Scene tree:\n" + str(extra["scene_tree"]))
    if extra.get("lint_output"):
        user_parts.append("Lint output:\n" + str(extra["lint_output"]))
    if extra.get("active_scene_path"):
        user_parts.append("Current scene: " + str(extra["active_scene_path"]))
    if extra.get("scene_dimension"):
        user_parts.append("Scene type: " + str(extra["scene_dimension"]))
    if request_context and request_context.current_script:
        user_parts.append("Active script: " + str(request_context.current_script))
    conv = extra.get("conversation_history")
    if conv and isinstance(conv, list) and len(conv) > 0:
        conv_lines = []
        for m in conv[-6:]:
            if isinstance(m, dict):
                r = m.get("role", "")
                c = m.get("content", "")
                if r and c is not None:
                    conv_lines.append(f"{r}: {str(c)[:500]}")
        if conv_lines:
            user_parts.append("Recent conversation:\n" + "\n".join(conv_lines))
    user_content = "\n\n".join(user_parts)

    messages: List[Dict[str, Any]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_content},
    ]
    _log_llm_input(model=model, context="composer", input_payload=messages)
    try:
        completion = client.chat.completions.create(model=model, messages=messages)
    except Exception as e:
        return (
            "Composer request failed: " + str(e),
            [],
            [],
            {"model": model, "limit_tokens": 0, "estimated_prompt_tokens": 0, "percent": 0.0},
        )
    content = (completion.choices[0].message.content or "").strip()
    usage = getattr(completion, "usage", None)
    prompt_tokens = getattr(usage, "prompt_tokens", None) or getattr(usage, "input_tokens", None) or 0
    completion_tokens = getattr(usage, "completion_tokens", None) or getattr(usage, "output_tokens", None) or 0
    if usage:
        record_usage(model, int(prompt_tokens), int(completion_tokens))
    answer, raw_tool_calls = _parse_composer_response(content)
    tool_results: List[ToolCallResult] = [
        ToolCallResult(tool_name=tc["name"], arguments=tc.get("arguments") or {}, output=None)
        for tc in raw_tool_calls
    ]
    limit = get_context_limit(model)
    context_usage = {
        "model": model,
        "limit_tokens": limit,
        "estimated_prompt_tokens": int(prompt_tokens),
        "percent": (int(prompt_tokens) + int(completion_tokens)) / limit if limit else 0.0,
    }
    return answer, [], tool_results, context_usage


@app.get("/health")
async def health() -> Dict[str, str]:
    """
    Simple health check so the Godot plugin can verify connectivity.
    """
    return {"status": "ok"}


@app.get("/test/backends")
async def test_backends() -> Dict[str, Any]:
    """
    Return backend identifiers, endpoints, and default models for testing and UI.
    Use this to switch between RAG (GPT-4.1-mini) and Godot Composer easily.
    """
    default_model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")
    composer_model = os.getenv("COMPOSER_MODEL") or default_model
    return {
        "rag": {
            "endpoint": "/query",
            "stream_endpoint": "/query_stream_with_tools",
            "default_model": default_model,
            "description": "RAG + tool loop (e.g. gpt-4.1-mini)",
        },
        "composer": {
            "endpoint": "/composer/query",
            "stream_endpoint": "/composer/query_stream_with_tools",
            "default_model": composer_model,
            "description": "Godot Composer fine-tuned model, tool_calls in response",
        },
    }


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


# --- Godot Composer (fine-tuned model, tool_calls directly) ---


@app.post("/composer/query", response_model=QueryResponseWithTools)
async def composer_query(payload: QueryRequest, request: Request) -> QueryResponseWithTools:
    """
    Godot Composer: single-turn call to a fine-tuned model that outputs tool_calls
    directly. Same request/response shape as /query so the plugin can switch by backend profile.
    """
    client_host = request.client.host if request.client else "unknown"
    _log_rag_request("POST /composer/query", client_host, payload.question or "", _green)
    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None
    answer, snippets, tool_calls, context_usage = _run_composer_query(
        question=question,
        context_language=context_language,
        request_context=payload.context,
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


@app.post("/composer/query_stream_with_tools")
async def composer_query_stream_with_tools(payload: QueryRequest, request: Request):
    """
    Same as /composer/query but streams answer text then __TOOL_CALLS__ + JSON.
    """
    client_host = request.client.host if request.client else "unknown"
    _log_rag_request("POST /composer/query_stream_with_tools", client_host, payload.question or "", _green)
    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    def run():
        return _run_composer_query(
            question=question,
            context_language=context_language,
            request_context=payload.context,
            api_key=payload.api_key,
            base_url=payload.base_url,
            model_override=payload.model,
        )

    answer, snippets, tool_calls, context_usage = await asyncio.to_thread(run)

    def stream_iter():
        chunk_size = 80
        for i in range(0, len(answer), chunk_size):
            yield answer[i : i + chunk_size]
        payload_list = [tc.model_dump() for tc in tool_calls]
        yield _STREAM_TOOL_CALLS_PREFIX + json.dumps(payload_list) + "\n"
        yield "\n__USAGE__\n" + json.dumps(context_usage) + "\n"

    return StreamingResponse(
        stream_iter(), media_type="text/plain; charset=utf-8"
    )


@app.post("/composer/query_stream")
async def composer_query_stream(payload: QueryRequest, request: Request):
    """
    Composer streaming (answer text only, no tool_calls suffix).
    """
    client_host = request.client.host if request.client else "unknown"
    _log_rag_request("POST /composer/query_stream", client_host, payload.question or "", _dim)
    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    def run():
        return _run_composer_query(
            question=question,
            context_language=context_language,
            request_context=payload.context,
            api_key=payload.api_key,
            base_url=payload.base_url,
            model_override=payload.model,
        )

    answer, _, _, _ = await asyncio.to_thread(run)

    def stream_iter():
        chunk_size = 80
        for i in range(0, len(answer), chunk_size):
            yield answer[i : i + chunk_size]

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

