#!/usr/bin/env python3
"""
Translate fine_tuning/data/synthetic/v2_generated.jsonl (or similar) into Composer v2 AGENT dataset.

This expects each record to have:
  {"messages": [{"role":"system"...}, {"role":"user"...}, {"role":"assistant"...}]}

We replace the system prompt with COMPOSER_V2_SYSTEM_PROMPT_AGENT and keep the assistant content
(including <tool_call> blocks).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from rag_service.app.prompts import COMPOSER_V2_SYSTEM_PROMPT_AGENT


def _load_jsonl(path: Path) -> Iterable[Dict[str, Any]]:
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            yield json.loads(line)


def _extract_user_assistant(messages: list[Dict[str, Any]]) -> Tuple[Optional[str], Optional[str]]:
    user_content: Optional[str] = None
    assistant_content: Optional[str] = None
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        content = m.get("content", "")
        if role == "user":
            user_content = str(content)
        elif role == "assistant":
            assistant_content = str(content)
    return user_content, assistant_content


def _has_tool_call_blocks(assistant_content: str) -> bool:
    return "<tool_call>" in assistant_content and "</tool_call>" in assistant_content


def translate_one_record(record: Dict[str, Any], require_tool_calls: bool) -> Optional[Dict[str, Any]]:
    messages = record.get("messages") or []
    if not isinstance(messages, list):
        return None
    user_content, assistant_content = _extract_user_assistant(messages)
    if not user_content or assistant_content is None:
        return None
    if require_tool_calls and not _has_tool_call_blocks(assistant_content):
        return None
    return {
        "messages": [
            {"role": "system", "content": COMPOSER_V2_SYSTEM_PROMPT_AGENT},
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Translate synthetic v2_generated JSONL -> Composer v2 AGENT dataset")
    parser.add_argument(
        "--input",
        type=str,
        default=str(REPO_ROOT / "fine_tuning" / "data" / "synthetic" / "v2_generated.jsonl"),
    )
    parser.add_argument(
        "--output",
        type=str,
        default=str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "agent_from_synthetic_v2_generated.jsonl"),
    )
    parser.add_argument("--require-tool-calls", action="store_true", default=True)
    parser.add_argument("--no-require-tool-calls", action="store_false", dest="require_tool_calls")
    args = parser.parse_args()

    in_path = Path(args.input)
    if not in_path.exists():
        raise SystemExit(f"Input not found: {in_path}")

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    written = 0
    skipped = 0
    with out_path.open("w", encoding="utf-8") as out_f:
        for rec in _load_jsonl(in_path):
            translated = translate_one_record(rec, require_tool_calls=args.require_tool_calls)
            if not translated:
                skipped += 1
                continue
            out_f.write(json.dumps(translated, ensure_ascii=False) + "\n")
            written += 1

    print(f"Wrote {written} records to {out_path}")
    print(f"Skipped {skipped} records")


if __name__ == "__main__":
    main()

