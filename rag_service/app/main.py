import asyncio
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

from dotenv import load_dotenv
from openai import OpenAI
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .rag_core import SourceChunk, _collect_code_results, _collect_top_docs
from .services.tools import (
    dispatch_tool_call,
    get_openai_tools_payload,
    get_registered_tools,
)
from .db import (
    create_edit_event,
    get_edit_event,
    init_db,
    list_edit_events,
    list_recent_file_changes,
)
from .repair_memory import (
    create_lint_fix_record,
    format_fixes_for_prompt,
    search_lint_fixes,
)
from .context_builder import (
    build_context_usage,
    build_ordered_blocks,
    build_related_files_context,
    blocks_to_user_content,
    get_context_limit,
    read_project_file,
    trim_text_to_tokens,
)


load_dotenv()  # Load environment variables from .env if present.

app = FastAPI(title="Godot RAG Service", version="0.1.0")
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
        "[usage] "
        f"context={context} "
        f"model={model} "
        f"prompt_tokens={prompt_tokens} "
        f"completion_tokens={completion_tokens} "
        f"total_tokens={total_tokens} "
        f"est_cost_usd={cost:.6f}"
    )


def _log_llm_input(model: str, context: str, input_payload: Any) -> None:
    """
    Debug log: dump the full input payload we send to the LLM.
    WARNING: This may be large. Do not include API keys here.
    """
    try:
        dumped = json.dumps(input_payload, ensure_ascii=False, indent=2)
    except Exception:
        dumped = str(input_payload)
    # Windows consoles can choke on box-drawing characters; normalize to a safe encoding.
    enc = getattr(sys.stdout, "encoding", None) or "utf-8"
    safe = dumped.encode(enc, errors="backslashreplace").decode(enc, errors="ignore")
    print(f"[llm_input] context={context} model={model}\n{safe}\n")


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
    top_k: int = 5
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
        "contains example scripts and shaders from various projects; treat these as patterns "
        "and inspiration, not as canonical definitions. "
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

    return completion.choices[0].message.content or ""


def _run_query_with_tools(
    question: str,
    context_language: Optional[str],
    request_context: Optional["QueryContext"],
    top_k: int,
    max_tool_rounds: int = 3,
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
    # If there is no LLM, fall back to the existing RAG-only path.
    if client is None:
        docs = _collect_top_docs(question, top_k=top_k)
        code_snippets = _collect_code_results(
            question=question,
            language=context_language,
            top_k=top_k,
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

    # Initial RAG step.
    docs = _collect_top_docs(question, top_k=top_k)
    code_snippets = _collect_code_results(
        question=question,
        language=context_language,
        top_k=top_k,
    )
    is_obscure = len(code_snippets) < max(1, top_k // 3)

    # --- Context builder (Stage 2): ordered blocks + budgets ---
    system_prompt = (
        "You are a Godot 4.x development assistant. "
        "You have access to:\n"
        "- Retrieved documentation (the 'docs' collection, scraped from the official Godot manuals).\n"
        "- Retrieved example project code snippets (the 'project_code' collection, non-canonical examples).\n"
        "- Search tools: 'search_docs' and 'search_project_code' to refine your search.\n"
        "- Editor tools (executed in the user's Godot editor):\n"
        "  - create_file, write_file: create or overwrite project files (e.g. res://scripts/foo.gd).\n"
        "  - apply_patch: replace old_string with new_string in a file.\n"
        "  - create_script: create a GDScript or C# script with extends and optional content.\n"
            "  - read_file: read a project file (res://...).\n"
            "  - list_directory: list entries under a project directory (res://...).\n"
            "  - search_files: search text inside project files under res://.\n"
            "  - delete_file: delete a project file (proposed via pending changes).\n"
        "  - create_node: add a node (any Godot type) to a scene under a parent path.\n"
        "  - set_node_property: set a property on a node (position, text, visible, etc.).\n\n"
        "Treat the docs collection as the authoritative source for engine behavior and APIs. "
        "Use project_code snippets as patterns and inspiration; when there is any conflict, prefer the docs. "
        "Use search tools when they will significantly improve your answer. "
        "Use editor tools when the user asks you to create or edit files, add nodes, or change properties. "
        "When the user explicitly asks to create a file (e.g. 'create test.gd' or 'create a file named X'), "
        "you MUST call create_file or write_file with the path and content; do not only show code in your message. "
        "When you are satisfied, return a final answer to the user."
    )

    # Extract active file info from request context (sent by the Godot editor).
    active_file_path = None
    active_file_text = None
    errors_text = None
    if request_context is not None:
        active_file_path = request_context.current_script or None
        extra = request_context.extra or {}
        active_file_text = extra.get("active_file_text") or None
        errors_text = extra.get("errors_text") or extra.get("lint_output") or None
        project_root_abs = extra.get("project_root_abs") or None
        engine_version = request_context.engine_version or None
    else:
        project_root_abs = None
        engine_version = None

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

    # Recency working set (SQLite): include the most recent diffs as lightweight context.
    recent_edits_text: List[str] = []
    try:
        recent = list_recent_file_changes(limit_edits=80, max_files=6)
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
    optional_extras: List[str] = []
    if context_language:
        optional_extras.append(f"Preferred language: {context_language}")
    if is_obscure:
        optional_extras.append(
            "Heuristic: This seems like an obscure area; consider lower-importance snippets too."
        )
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
    )
    user_content, _dbg = blocks_to_user_content(blocks)
    user_content += (
        "\n\nYou may call search_docs/search_project_code for more context, or editor tools "
        "(create_file, write_file, apply_patch, create_script, create_node, set_node_property) "
        "when the user wants changes in the project. If the existing context is enough, answer directly.\n"
    )

    messages: List[Dict[str, Any]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_content},
    ]

    tools_payload = get_openai_tools_payload()

    tool_call_results: List[ToolCallResult] = []
    total_prompt_tokens = 0
    total_completion_tokens = 0

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
    usage_obj = build_context_usage(model, [question])
    return fallback_answer, docs + code_snippets, tool_call_results, {
        "model": usage_obj.model,
        "limit_tokens": usage_obj.limit_tokens,
        "estimated_prompt_tokens": usage_obj.estimated_prompt_tokens,
        "percent": usage_obj.percent,
    }


@app.get("/health")
async def health() -> Dict[str, str]:
    """
    Simple health check so the Godot plugin can verify connectivity.
    """
    return {"status": "ok"}


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


@app.post("/edit_events/create")
async def edit_events_create(payload: EditEventIn) -> Dict[str, Any]:
    edit_id = create_edit_event(
        actor=payload.actor,
        trigger=payload.trigger,
        summary=payload.summary,
        prompt=payload.prompt,
        changes=[c.model_dump() for c in payload.changes],
    )
    return {"ok": True, "edit_id": edit_id}


@app.get("/edit_events/list")
async def edit_events_list(limit: int = 100) -> Dict[str, Any]:
    return {"ok": True, "events": list_edit_events(limit=int(limit))}


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
    print(f"[RAG] /query from {client_host}: {payload.question!r}")

    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    answer, snippets, tool_calls, context_usage = _run_query_with_tools(
        question=question,
        context_language=context_language,
        request_context=payload.context,
        top_k=payload.top_k,
        max_tool_rounds=3,
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
    print(f"[RAG] /query_stream_with_tools from {client_host}: {payload.question!r}")

    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    def run():
        return _run_query_with_tools(
            question=question,
            context_language=context_language,
            request_context=payload.context,
            top_k=payload.top_k,
            max_tool_rounds=3,
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
    print(f"[RAG] /query_stream from {client_host}: {payload.question!r}")

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
        "contains example scripts and shaders from various projects; treat these as patterns "
        "and inspiration, not as canonical definitions. "
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

    return StreamingResponse(stream_iter(), media_type="text/plain; charset=utf-8")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)

