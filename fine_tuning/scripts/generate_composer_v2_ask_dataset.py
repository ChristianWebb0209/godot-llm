#!/usr/bin/env python3
"""
Generate Composer v2 ASK-mode dataset via OpenAI API calls.

Outputs JSONL where each line is:
  {"messages": [
      {"role":"system","content": COMPOSER_V2_SYSTEM_PROMPT_ASK},
      {"role":"user","content": <ambiguous editor-agent request>},
      {"role":"assistant","content": <exactly one short question ending with '?'>}
   ]}

Enforcement:
- assistant content contains NO <tool_call> blocks
- assistant content contains NO __OPTIONS__
- assistant content ends with '?'
- assistant content has no additional text beyond the single question
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

# Load API keys/settings (used for OpenAI generation).
try:
    from dotenv import load_dotenv

    load_dotenv(REPO_ROOT / "fine_tuning" / ".env")
    load_dotenv(REPO_ROOT / ".env")
except Exception:
    pass

from rag_service.app.prompts import COMPOSER_V2_SYSTEM_PROMPT_ASK


def _load_json_from_maybe_fenced(text: str) -> Any:
    s = (text or "").strip()
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    return json.loads(s)


def validate_ask_example(assistant_content: str) -> tuple[bool, Optional[str]]:
    s = (assistant_content or "").strip()
    if not s:
        return False, "empty_assistant"
    if "<tool_call>" in s or "</tool_call>" in s:
        return False, "contains_tool_call_blocks"
    if "__OPTIONS__" in s:
        return False, "contains___OPTIONS__"

    # Single question: must end with '?' and contain no additional lines/preamble.
    if not s.endswith("?"):
        return False, "does_not_end_with_question_mark"
    if "\n" in s.strip():
        return False, "contains_newlines"

    # Avoid multi-question output.
    if s.count("?") != 1:
        return False, "multiple_questions"

    # Shouldn't look like tool-call JSON.
    if "<" in s and "?" not in s:
        # Too strict; keep as a weak check.
        return True, None

    return True, None


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Composer v2 ASK dataset via OpenAI")
    parser.add_argument("--model", type=str, default=os.getenv("OPENAI_MODEL", "gpt-4o-mini"))
    parser.add_argument("--count", type=int, default=100, help="Examples per API call")
    parser.add_argument("--batches", type=int, default=10, help="Number of API calls")
    parser.add_argument("--temperature", type=float, default=0.6)
    parser.add_argument("--max-tokens", type=int, default=800)
    parser.add_argument(
        "--output",
        type=str,
        default=str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "ask_generated.jsonl"),
    )
    args = parser.parse_args()

    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("Set OPENAI_API_KEY in environment to run this generator.")

    try:
        from openai import OpenAI
    except ImportError:
        raise SystemExit("Missing dependency: install openai (pip install openai).")

    client = OpenAI(api_key=api_key)

    system_prompt = (
        "You are generating training examples for a Godot editor assistant (Composer v2) in ASK mode.\n"
        "Return ONLY a JSON array.\n"
        "Each array element is an object with exactly two keys:\n"
        "  - user: string (ambiguous request that requires clarification before acting in the editor)\n"
        "  - assistant: string (the assistant's output)\n"
        "\n"
        "assistant MUST be exactly one short clarifying question and nothing else.\n"
        "Rules:\n"
        "- assistant ends with a single '?'\n"
        "- assistant contains NO <tool_call> blocks\n"
        "- assistant contains NO __OPTIONS__\n"
        "- assistant contains no newlines\n"
    )

    user_prompt = (
        f"Generate exactly {args.count} examples.\n"
        "Ambiguity guidance:\n"
        "- Requests should describe an editor action (connect signals, edit a specific script, create a node, etc.)\n"
        "- But omit at least one key detail needed to act safely (which node path, which script, which function name, etc.)\n"
    )

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    written = 0
    skipped = 0
    fail_reasons: Dict[str, int] = {}

    with out_path.open("w", encoding="utf-8") as out_f:
        for _b in range(args.batches):
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

                ok, reason = validate_ask_example(assistant)
                if not ok:
                    skipped += 1
                    fail_reasons[reason or "invalid"] = fail_reasons.get(reason or "invalid", 0) + 1
                    continue

                record = {
                    "messages": [
                        {"role": "system", "content": COMPOSER_V2_SYSTEM_PROMPT_ASK},
                        {"role": "user", "content": user},
                        {"role": "assistant", "content": assistant.strip()},
                    ]
                }
                out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
                written += 1

    print(f"Wrote {written} ask records to {out_path}")
    print(f"Skipped {skipped} records")
    if fail_reasons:
        print("Top skip reasons:")
        for k, v in sorted(fail_reasons.items(), key=lambda kv: -kv[1])[:10]:
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()

