#!/usr/bin/env python3
"""
Generate ultra-sharp synthetic (user prompt -> tool_calls) examples using an AI API.
Produces highly focused examples with zero rambling, zero markdown, and perfect JSON arguments.

Usage:
  python fine_tuning/scripts/generate_sharp_tool_examples.py [--count 20] [--batches 5]
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

# Add the repo root to sys.path so we can import load_schema and other utils
REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(REPO_ROOT / "fine_tuning" / "scripts"))

try:
    from dotenv import load_dotenv
    load_dotenv(REPO_ROOT / "fine_tuning" / ".env")
    load_dotenv(REPO_ROOT / ".env")
except ImportError:
    pass

try:
    # Re-use utilities from our main generator
    from generate_tool_examples import load_schema, call_openai, build_messages_example, validate_tool_call
except ImportError as e:
    sys.stderr.write(f"Failed to import generate_tool_examples utilities: {e}\n")
    sys.exit(1)

DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
SYNTHETIC_DIR = DATA_DIR / "synthetic"
OUTPUT_JSONL = SYNTHETIC_DIR / "sharp_generated.jsonl"

SHARP_SYSTEM_PROMPT = """You are generating training examples for a Godot 4.x coding assistant that uses tools.
You will be given a JSON array of tool definitions.
For each example output a single JSON object with exactly two keys:
  "user": string — a very short, specific, and direct user query or imperative command (e.g. "Search docs for rigidbody", "List files in res://src", "Read res://player.gd").
  "tool_calls": array — exactly one or two precise tool calls answering the query. {"name": "<exact tool name>", "arguments": { ... }}.

CRITICAL RULES:
- Zero rambling. The user prompt must be unambiguous and very short (under 10 words).
- The `tool_calls` arguments must be perfectly matched to the schema. No hallucinated parameters.
- No `content` for the assistant at all. The assistant emits ONLY the `tool_calls`.
- Output ONLY a JSON array of these objects, no markdown.

Example:
[{"user": "Search docs for CharacterBody2D", "tool_calls": [{"name": "search_docs", "arguments": {"query": "CharacterBody2D"}}]},
 {"user": "What signals does Area2D have?", "tool_calls": [{"name": "get_signals", "arguments": {"node_type": "Area2D"}}]}]"""

def call_openai_sharp(
    tools_schema: list,
    count: int,
    model: str,
    api_key: str,
) -> list[dict]:
    tools_blob = json.dumps(tools_schema, indent=2)
    user_content = f"Generate exactly {count} short, sharp tool-use training examples. Tools schema:\n{tools_blob}"
    
    try:
        from openai import OpenAI
    except ImportError:
        sys.stderr.write("Install openai: pip install openai\n")
        sys.exit(1)

    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SHARP_SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ],
        temperature=0.6, # slightly lower for more strict/clean outputs
    )
    text = (response.choices[0].message.content or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"API returned invalid JSON: {e}\nRaw:\n{text[:500]}\n")
        return []

def main() -> None:
    parser = argparse.ArgumentParser(description="Generate ultra-sharp synthetic tool-use examples via AI")
    parser.add_argument("--count", type=int, default=20, help="Number of examples per API call")
    parser.add_argument("--model", default="gpt-4o", help="OpenAI model")
    parser.add_argument("--batches", type=int, default=1, help="Number of API calls")
    parser.add_argument("--system", default="You are a Godot assistant. Use the available tools when needed.", help="System message for each example")
    args = parser.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write("Set OPENAI_API_KEY to use the API.\n")
        sys.exit(1)

    schema = load_schema()
    schema_by_name = {t["name"]: t for t in schema}

    SYNTHETIC_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    skipped = 0

    for batch in range(args.batches):
        raw = call_openai_sharp(schema, args.count, args.model, api_key)
        if not isinstance(raw, list):
            raw = [raw] if raw else []
        for item in raw:
            user = item.get("user") or item.get("user_message") or ""
            tcs = item.get("tool_calls") or []
            if not user or not tcs:
                skipped += 1
                continue
            
            all_ok = True
            for tc in tcs:
                name = tc.get("name") or tc.get("function", {}).get("name")
                args_val = tc.get("arguments")
                if isinstance(args_val, str):
                    try:
                        args_val = json.loads(args_val)
                    except json.JSONDecodeError:
                        args_val = {}
                if not name:
                    all_ok = False
                    break
                errs = validate_tool_call(name, args_val or {}, schema_by_name)
                if errs:
                    all_ok = False
                    break
            
            if not all_ok:
                skipped += 1
                continue
                
            tc_list = []
            for tc in tcs:
                n = tc.get("name") or tc.get("function", {}).get("name")
                args_val = tc.get("arguments")
                if isinstance(args_val, str):
                    args_val = json.loads(args_val) if args_val else {}
                tc_list.append({"name": n, "arguments": args_val or {}})
            
            # Sharp records: content is strictly empty
            record = build_messages_example(user, tc_list, args.system)
            for msg in record["messages"]:
                if msg["role"] == "assistant":
                    msg["content"] = "" # Force empty
            
            with open(OUTPUT_JSONL, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            written += 1

    print(f"Appended {written} valid sharp examples to {OUTPUT_JSONL} (skipped {skipped})")

if __name__ == "__main__":
    main()
