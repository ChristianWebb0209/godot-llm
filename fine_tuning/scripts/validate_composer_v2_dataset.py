#!/usr/bin/env python3
"""
Validate a Composer v2 dataset JSONL file.

Expected record format:
  {"messages":[
      {"role":"system","content": <composer system prompt>},
      {"role":"user","content": ...},
      {"role":"assistant","content": ...}
  ]}

Validates:
- No __OPTIONS__
- AGENT mode:
  - assistant contains >= 1 <tool_call> blocks
  - tool_call inner JSON parses
  - tool name exists in fine_tuning/schemas/tools.json
  - arguments is a dict, required keys present, and basic type checks pass when available
  - no extra text outside optional <think> and tool blocks
- ASK mode:
  - assistant contains no <tool_call> blocks
  - assistant ends with exactly one '?' and has no newlines

Run:
  python fine_tuning/scripts/validate_composer_v2_dataset.py --input path/to/dataset.jsonl --mode agent
  python fine_tuning/scripts/validate_composer_v2_dataset.py --input path/to/dataset.jsonl --mode ask
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from rag_service.app.prompts import COMPOSER_V2_SYSTEM_PROMPT_AGENT, COMPOSER_V2_SYSTEM_PROMPT_ASK


TOOLS_JSON = REPO_ROOT / "fine_tuning" / "schemas" / "tools.json"


def _load_jsonl(path: Path) -> Iterable[Dict[str, Any]]:
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            yield json.loads(line)


def _load_tools_schema() -> List[Dict[str, Any]]:
    if not TOOLS_JSON.exists():
        raise SystemExit(f"tools schema not found: {TOOLS_JSON}")
    return json.loads(TOOLS_JSON.read_text(encoding="utf-8"))


def _extract_assistant_content(record: Dict[str, Any]) -> Tuple[Optional[str], Optional[str]]:
    messages = record.get("messages") or []
    if not isinstance(messages, list):
        return None, None
    system = None
    assistant = None
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        if role == "system":
            system = str(m.get("content") or "")
        elif role == "assistant":
            assistant = str(m.get("content") or "")
    return system, assistant


def _extract_tool_call_blocks(assistant_content: str) -> List[str]:
    pattern = r"<tool_call>\s*(.*?)\s*</tool_call>"
    return [m.strip() for m in re.findall(pattern, assistant_content, flags=re.DOTALL)]


def _strip_think_and_tool_blocks(assistant_content: str) -> str:
    assistant_content = re.sub(r"<tool_call>\s*.*?\s*</tool_call>", "", assistant_content, flags=re.DOTALL)
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
    return True


def _validate_tool_call_inner(
    inner_json_str: str,
    schema_by_name: Dict[str, Dict[str, Any]],
) -> Tuple[bool, Optional[str]]:
    try:
        payload = json.loads(inner_json_str)
    except json.JSONDecodeError:
        return False, "tool_call_inner_json_invalid"

    name = payload.get("name")
    if not name or name not in schema_by_name:
        return False, "unknown_tool_name"

    args = payload.get("arguments") or {}
    if not isinstance(args, dict):
        return False, "arguments_not_dict"

    tool_schema = schema_by_name[name]
    params = tool_schema.get("parameters") or {}
    required = params.get("required") or []
    for req in required:
        if req not in args:
            return False, f"missing_required_arg:{req}"

    props = params.get("properties") or {}
    for arg_name, arg_val in args.items():
        prop = props.get(arg_name)
        if not isinstance(prop, dict):
            continue
        expected_type = prop.get("type")
        if expected_type and not _type_matches(str(expected_type), arg_val):
            return False, f"type_mismatch:{arg_name}"

    return True, None


def validate_agent_assistant(assistant_content: str, schema_by_name: Dict[str, Dict[str, Any]]) -> Tuple[bool, Optional[str]]:
    if "__OPTIONS__" in assistant_content:
        return False, "has___OPTIONS__"

    tool_inners = _extract_tool_call_blocks(assistant_content)
    if not tool_inners:
        return False, "no_tool_call_blocks"

    for inner in tool_inners:
        ok, reason = _validate_tool_call_inner(inner, schema_by_name=schema_by_name)
        if not ok:
            return False, reason

    leftover = _strip_think_and_tool_blocks(assistant_content)
    if leftover:
        return False, "extra_text_outside_tool_blocks"

    return True, None


def validate_ask_assistant(assistant_content: str) -> Tuple[bool, Optional[str]]:
    if "__OPTIONS__" in assistant_content:
        return False, "has___OPTIONS__"
    if "<tool_call>" in assistant_content or "</tool_call>" in assistant_content:
        return False, "contains_tool_call_blocks"

    s = assistant_content.strip()
    if not s.endswith("?"):
        return False, "does_not_end_with_question_mark"
    if "\n" in s:
        return False, "contains_newlines"
    if s.count("?") != 1:
        return False, "multiple_questions"
    return True, None


def infer_mode_from_system(system_prompt: str) -> Optional[str]:
    if not system_prompt:
        return None
    if system_prompt == COMPOSER_V2_SYSTEM_PROMPT_AGENT:
        return "agent"
    if system_prompt == COMPOSER_V2_SYSTEM_PROMPT_ASK:
        return "ask"
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate Composer v2 dataset JSONL")
    parser.add_argument("--input", type=str, required=True)
    parser.add_argument("--mode", type=str, default="infer", choices=["infer", "agent", "ask"])
    parser.add_argument(
        "--output",
        type=str,
        default="",
        help="Optional output path to write only valid records (JSONL). If empty, just prints stats.",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        raise SystemExit(f"Input not found: {input_path}")

    tools_schema = _load_tools_schema()
    schema_by_name: Dict[str, Dict[str, Any]] = {t["name"]: t for t in tools_schema if isinstance(t, dict) and t.get("name")}

    out_path = Path(args.output) if args.output else None
    if out_path:
        out_path.parent.mkdir(parents=True, exist_ok=True)

    total = 0
    valid = 0
    skipped = 0
    fail_reasons: Dict[str, int] = {}

    writer = out_path.open("w", encoding="utf-8") if out_path else None
    try:
        for rec in _load_jsonl(input_path):
            total += 1
            system_prompt, assistant = _extract_assistant_content(rec)
            if assistant is None:
                skipped += 1
                continue

            mode = args.mode
            if mode == "infer":
                mode = infer_mode_from_system(system_prompt) or ""

            if mode not in ("agent", "ask"):
                skipped += 1
                continue

            if mode == "agent":
                ok, reason = validate_agent_assistant(assistant, schema_by_name=schema_by_name)
            else:
                ok, reason = validate_ask_assistant(assistant)

            if not ok:
                skipped += 1
                fail_reasons[reason or "invalid"] = fail_reasons.get(reason or "invalid", 0) + 1
                continue

            valid += 1
            if writer:
                writer.write(json.dumps(rec, ensure_ascii=False) + "\n")

    finally:
        if writer:
            writer.close()

    print(f"Validated {total} records from {input_path}")
    print(f"Valid:   {valid}")
    print(f"Skipped: {skipped}")
    if fail_reasons:
        print("Top fail reasons:")
        for k, v in sorted(fail_reasons.items(), key=lambda kv: -kv[1])[:15]:
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()

