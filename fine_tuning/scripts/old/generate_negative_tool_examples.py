#!/usr/bin/env python3
"""
Generate synthetic (user prompt -> assistant answer) examples using an AI API.
These are negative examples where the model should NOT use any tools, but instead
just answer directly (e.g., conceptual Godot questions, explaining API usage, etc.).
This trains the model to not hallucinate tool calls when it's not appropriate.

Usage:
  python fine_tuning/scripts/generate_negative_tool_examples.py [--count 20] [--batches 5]
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
try:
    from dotenv import load_dotenv
    load_dotenv(REPO_ROOT / "fine_tuning" / ".env")
    load_dotenv(REPO_ROOT / ".env")
except ImportError:
    pass

DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
SYNTHETIC_DIR = DATA_DIR / "synthetic"
OUTPUT_JSONL = SYNTHETIC_DIR / "negative_generated.jsonl"

SYSTEM_PROMPT = """You are generating negative training examples for a Godot 4.x coding assistant.
Your goal is to generate examples where the user asks a Godot-related question and the assistant provides a helpful text response WITHOUT calling any tools.

Rules for generation:
1. "user": The user asks a Godot 4 question that doesn't require tools. Examples: "What is a Node in Godot?", "How does move_and_slide work?", "Explain the difference between _process and _physics_process", "Can you give me an example of GDScript syntax for an array?"
2. "assistant": The assistant provides a helpful, short conceptual answer. NO tools should be called. Do not include any `tool_calls` key or `<tool_call>` tags, just plain text "content".
3. Provide exactly {count} diverse and realistic Q&A pairs about Godot.

Format output as a JSON array of objects with exactly two keys: "user" and "assistant" string content.
Example:
[
  {"user": "What is the difference between @export and @onready?", "assistant": "@export exposes a variable to the Godot editor inspector so you can modify it from the UI. @onready delays the initialization of a variable until the Node has entered the scene tree, commonly used for getting node references like `@onready var sprite = $Sprite2D`."},
  {"user": "How do I instantiate a scene in GDScript?", "assistant": "To instantiate a scene, first load it using `load()` or `preload()`, then call `instantiate()` on the PackedScene. For example:\n```gdscript\nvar my_scene = preload(\"res://enemy.tscn\")\nvar instance = my_scene.instantiate()\nadd_child(instance)\n```"}
]
"""

def build_messages_example(user: str, assistant_content: str, system_content: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": system_content},
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant_content},
        ]
    }

def call_openai(count: int, model: str, api_key: str) -> list[dict]:
    try:
        from openai import OpenAI
    except ImportError:
        sys.stderr.write("Install openai: pip install openai\n")
        sys.exit(1)

    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT.format(count=count)},
            {"role": "user", "content": f"Generate {count} negative tool examples about Godot 4."}
        ],
        temperature=0.8,
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
    parser = argparse.ArgumentParser(description="Generate negative (no tool) tool-use examples via AI")
    parser.add_argument("--count", type=int, default=20, help="Number of examples per API call")
    parser.add_argument("--model", default="gpt-4o", help="OpenAI model (e.g. gpt-4o, gpt-4o-mini)")
    parser.add_argument("--batches", type=int, default=1, help="Number of API calls (total examples = count * batches)")
    parser.add_argument("--system", default="You are a Godot assistant. Use the available tools when needed.", help="System message for each example")
    args = parser.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write("Set OPENAI_API_KEY to use the API.\n")
        sys.exit(1)

    SYNTHETIC_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    skipped = 0

    for batch in range(args.batches):
        raw = call_openai(args.count, args.model, api_key)
        if not isinstance(raw, list):
            raw = [raw] if raw else []
        for item in raw:
            user = item.get("user") or ""
            assistant = item.get("assistant") or ""
            if not user or not assistant:
                skipped += 1
                continue
            
            record = build_messages_example(user, assistant, args.system)
            with open(OUTPUT_JSONL, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            written += 1

    print(f"Appended {written} negative examples to {OUTPUT_JSONL} (skipped {skipped})")

if __name__ == "__main__":
    main()
