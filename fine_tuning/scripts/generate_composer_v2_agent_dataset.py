#!/usr/bin/env python3
"""
Generate Composer v2 AGENT-mode dataset via OpenAI API calls.

Outputs JSONL where each line is:
  {"messages": [{"role":"system","content": COMPOSER_V2_SYSTEM_PROMPT_AGENT},
                 {"role":"user","content": <short editor-agent request>},
                 {"role":"assistant","content": "<tool_call>...</tool_call> blocks only"}]}

Enforcement:
- assistant content contains >= 1 <tool_call> blocks
- no __OPTIONS__
- inner JSON parses and tool name exists in fine_tuning/schemas/tools.json
- required argument keys exist and argument types are correct when schema provides types
- assistant content contains no extra text outside optional <think> blocks and tool blocks
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

# Load API keys/settings (used for OpenAI generation).
try:
    from dotenv import load_dotenv

    load_dotenv(REPO_ROOT / "fine_tuning" / ".env")
    load_dotenv(REPO_ROOT / ".env")
except Exception:
    # It's okay if env vars are already set; dotenv is just a convenience.
    pass

from rag_service.app.prompts import COMPOSER_V2_SYSTEM_PROMPT_AGENT


TOOLS_JSON = REPO_ROOT / "fine_tuning" / "schemas" / "tools.json"


def _load_tools_schema() -> List[Dict[str, Any]]:
    if not TOOLS_JSON.exists():
        raise SystemExit(f"tools schema not found: {TOOLS_JSON}")
    return json.loads(TOOLS_JSON.read_text(encoding="utf-8"))


def _schema_brief(schema: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Reduce token load: keep only name + required keys + rough type hints.
    """
    out: List[Dict[str, Any]] = []
    for t in schema:
        name = t.get("name")
        params = t.get("parameters") or {}
        required = params.get("required") or []
        props = params.get("properties") or {}
        type_hints: Dict[str, Any] = {}
        for k, v in props.items():
            if not isinstance(v, dict):
                continue
            typ = v.get("type")
            if typ:
                type_hints[k] = {"type": typ}
        out.append({"name": name, "required": required, "properties": type_hints})
    return out


def _extract_tool_call_inners(assistant_content: str) -> List[str]:
    pattern = r"<tool_call>\s*(.*?)\s*</tool_call>"
    return [m.strip() for m in re.findall(pattern, assistant_content, flags=re.DOTALL)]


def _strip_think_and_tool_blocks(assistant_content: str) -> str:
    # Remove tool_call blocks
    assistant_content = re.sub(r"<tool_call>\s*.*?\s*</tool_call>", "", assistant_content, flags=re.DOTALL)
    # Remove optional think blocks
    assistant_content = re.sub(r"<think>.*?</think>", "", assistant_content, flags=re.DOTALL)
    return assistant_content.strip()


def _type_matches(expected_type: str, value: Any) -> bool:
    expected_type = expected_type.lower()
    if expected_type == "string":
        return isinstance(value, str)
    if expected_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected_type == "boolean":
        return isinstance(value, bool)
    if expected_type == "array":
        return isinstance(value, list)
    # If schema has unknown type, don't fail hard.
    return True


def _validate_arguments_against_schema(
    name: str,
    arguments: Any,
    schema_by_name: Dict[str, Dict[str, Any]],
) -> Tuple[bool, Optional[str]]:
    if not isinstance(arguments, dict):
        return False, "arguments_not_dict"

    tool_schema = schema_by_name.get(name) or {}
    params = tool_schema.get("parameters") or {}
    required = params.get("required") or []
    for req in required:
        if req not in arguments:
            return False, f"missing_required_arg:{req}"

    props = params.get("properties") or {}
    for arg_name, arg_val in arguments.items():
        prop = props.get(arg_name)
        if not isinstance(prop, dict):
            continue
        expected_type = prop.get("type")
        if expected_type and not _type_matches(str(expected_type), arg_val):
            return False, f"type_mismatch:{arg_name}"

    return True, None


def validate_agent_example(assistant_content: str, schema_by_name: Dict[str, Dict[str, Any]]) -> Tuple[bool, Optional[str]]:
    if "__OPTIONS__" in assistant_content:
        return False, "has___OPTIONS__"
    inners = _extract_tool_call_inners(assistant_content)
    if not inners:
        return False, "no_tool_call_blocks"

    for inner_str in inners:
        try:
            payload = json.loads(inner_str)
        except json.JSONDecodeError:
            return False, "tool_call_inner_json_invalid"
        name = payload.get("name")
        if not name or name not in schema_by_name:
            return False, "unknown_or_missing_tool_name"
        args = payload.get("arguments") or {}
        ok, _reason = _validate_arguments_against_schema(str(name), args, schema_by_name)
        if not ok:
            return False, _reason

    # Ensure we don't have extra text outside tool blocks/optional <think>.
    leftover = _strip_think_and_tool_blocks(assistant_content)
    if leftover:
        return False, "extra_text_outside_tool_blocks"

    return True, None


def _load_json_from_maybe_fenced(text: str) -> Any:
    s = (text or "").strip()
    if s.startswith("```"):
        # Remove code fence markers
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    return json.loads(s)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Composer v2 AGENT dataset via OpenAI")
    parser.add_argument("--model", type=str, default=os.getenv("OPENAI_MODEL", "gpt-4o-mini"))
    parser.add_argument("--count", type=int, default=100, help="Examples per API call")
    parser.add_argument("--batches", type=int, default=10, help="Number of API calls")
    parser.add_argument("--temperature", type=float, default=0.5)
    parser.add_argument("--max-tokens", type=int, default=2500)
    parser.add_argument(
        "--output",
        type=str,
        default=str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "agent_generated.jsonl"),
    )
    args = parser.parse_args()

    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("Set OPENAI_API_KEY in environment to run this generator.")

    schema = _load_tools_schema()
    schema_by_name: Dict[str, Dict[str, Any]] = {t["name"]: t for t in schema if isinstance(t, dict) and t.get("name")}
    schema_brief = _schema_brief(schema)

    try:
        from openai import OpenAI
    except ImportError:
        raise SystemExit("Missing dependency: install openai (pip install openai).")

    client = OpenAI(api_key=api_key)

    system_prompt = (
        "You are generating training examples for a Godot editor assistant (Composer v2) that emits XML tool calls.\n"
        "Return ONLY a JSON array.\n"
        "Each array element is an object with exactly two keys:\n"
        "  - user: string (short request that requires editor actions)\n"
        "  - assistant: string (assistant content)\n"
        "\n"
        "assistant MUST consist of ONLY one or more XML blocks:\n"
        "<tool_call>{\"name\": \"tool_name\", \"arguments\": {...}}</tool_call>\n"
        "No conversational text. No __OPTIONS__. No code fences.\n"
        "\n"
        "Use ONLY tools from the provided schema. Tool call inner JSON arguments must be dictionaries.\n"
        "You may include optional <think>...</think> blocks, but nothing else beyond tool blocks.\n"
    )

    user_prompt = (
        "Tools schema (brief):\n"
        f"{json.dumps(schema_brief, ensure_ascii=False)}\n\n"
        f"Generate exactly {args.count} examples.\n"
        "User prompts must be short and specific.\n"
    )

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    written = 0
    skipped = 0
    fail_reasons: Dict[str, int] = {}

    with out_path.open("w", encoding="utf-8") as out_f:
        for b in range(args.batches):
            resp = client.chat.completions.create(
                model=args.model,
                messages=[{"role": "system", "content": system_prompt}, {"role": "user", "content": user_prompt}],
                temperature=args.temperature,
                max_tokens=args.max_tokens,
            )
            raw_text = (resp.choices[0].message.content or "").strip()
            if not raw_text:
                continue

            try:
                items = _load_json_from_maybe_fenced(raw_text)
            except Exception:
                continue

            if not isinstance(items, list):
                continue

            for item in items:
                if not isinstance(item, dict):
                    skipped += 1
                    continue
                user = str(item.get("user") or "").strip()
                assistant = str(item.get("assistant") or "")
                if not user or not assistant:
                    skipped += 1
                    continue

                ok, reason = validate_agent_example(assistant, schema_by_name=schema_by_name)
                if not ok:
                    skipped += 1
                    fail_reasons[reason or "invalid"] = fail_reasons.get(reason or "invalid", 0) + 1
                    continue

                record = {
                    "messages": [
                        {"role": "system", "content": COMPOSER_V2_SYSTEM_PROMPT_AGENT},
                        {"role": "user", "content": user},
                        {"role": "assistant", "content": assistant},
                    ]
                }
                out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
                written += 1

    print(f"Wrote {written} agent records to {out_path}")
    print(f"Skipped {skipped} records")
    if fail_reasons:
        print("Top skip reasons:")
        for k, v in sorted(fail_reasons.items(), key=lambda kv: -kv[1])[:10]:
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()

