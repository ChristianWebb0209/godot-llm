#!/usr/bin/env python3
"""
Generate synthetic (user prompt -> tool_calls) examples using an AI API.
Reads fine_tuning/schemas/tools.json, calls OpenAI (or compatible) to produce
valid examples, validates them, and appends to fine_tuning/data/synthetic/generated.jsonl.

Canonical tool list: rag_service/app/services/tools.py (get_registered_tools).
Re-export tools.json after any change to tools.py: run export_tool_schema.py from repo root.

Usage (from repo root):
  python fine_tuning/scripts/generate_tool_examples.py [--count 20] [--batches 5]
  # With focus seeds (reduces duplicates across batches):
  python fine_tuning/scripts/generate_tool_examples.py --count 20 --batches 5 --seeds fine_tuning/data/seeds/batch_nodes_2d.json
  # Different seeds per batch (round-robin):
  python fine_tuning/scripts/generate_tool_examples.py --count 20 --batches 5 --seeds-dir fine_tuning/data/seeds
  # Resume after interruption (e.g. 3399 examples = 68 batches done; do remaining 32):
  python fine_tuning/scripts/generate_tool_examples.py --count 50 --batches 33 --seeds-dir fine_tuning/data/seeds --start-batch 68 --model gpt-4o-mini

Seeds JSON keys: node_types, extends_classes, scene_paths, script_paths, tools_to_prioritize.
Output: one JSON object per line, each with "messages" (system, user, assistant with tool_calls).
Requires: pip install openai. Export tools.json first (run export_tool_schema.py from repo root with rag_service deps).
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# Load .env so OPENAI_API_KEY is available (fine_tuning/.env or repo root)
try:
    from dotenv import load_dotenv
    load_dotenv(REPO_ROOT / "fine_tuning" / ".env")
    load_dotenv(REPO_ROOT / ".env")
except ImportError:
    pass
SCHEMAS_DIR = REPO_ROOT / "fine_tuning" / "schemas"
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
SYNTHETIC_DIR = DATA_DIR / "synthetic"
TOOLS_JSON = SCHEMAS_DIR / "tools.json"
OUTPUT_JSONL = SYNTHETIC_DIR / "generated.jsonl"

SYSTEM_PROMPT = """You are generating training examples for a Godot 4.x coding assistant that uses tools.
You will be given a JSON array of tool definitions (name, description, parameters with type/required).
For each example output a single JSON object with exactly two keys:
  "user": string — a short, realistic user message (e.g. "Create a script at res://scripts/enemy.gd that extends CharacterBody2D", "Run the main scene headlessly and show errors", "What signals does Button have?", "List autoloads").
  "tool_calls": array — one or more tool calls. Each item: {"name": "<exact tool name>", "arguments": { ... }}. Arguments must match the tool's parameters (required keys present, correct types). Use res:// paths for Godot. No call_id or id needed.

Rules:
- Tool names must be exactly as in the schema. The schema includes: file ops (create_file, write_file, apply_patch, ...), read/explore (read_file, list_directory, search_files, grep_search), docs (search_docs), nodes (create_node, modify_attribute, get_node_tree, get_signals, connect_signal, get_export_vars), run (run_terminal_command, run_godot_headless, run_scene), project (get_project_settings, get_autoloads, get_input_map), and Godot-specific (search_asset_library, check_errors, get_recent_changes, fetch_url). Cover a diverse mix including Godot-specific tools.
- Use Godot 4.x GDScript conventions and res:// paths. Arguments: path strings for res://, numbers within min/max, etc.
- One user message can trigger 1–3 tool calls when natural (e.g. create_file then write_file; or get_node_tree then connect_signal).
- When you receive a FOCUS for this batch (node types, scenes, tools, etc.), use those as the main topics: vary your examples around them and do NOT repeat the same (tool, key args like node_type/path) twice in this batch.
- Output ONLY a JSON array of such objects, no markdown or explanation. Example:
[{"user": "Add a CharacterBody2D node to the current scene.", "tool_calls": [{"name": "create_node", "arguments": {"node_type": "CharacterBody2D"}}]}, {"user": "Run res://main.tscn headlessly.", "tool_calls": [{"name": "run_scene", "arguments": {"scene_path": "res://main.tscn"}}]}, {"user": "What inputs are configured?", "tool_calls": [{"name": "get_input_map", "arguments": {}}]}]"""


def load_schema() -> list:
    if not TOOLS_JSON.exists():
        sys.stderr.write(f"Run export_tool_schema.py first so that {TOOLS_JSON} exists.\n")
        sys.exit(1)
    with open(TOOLS_JSON, encoding="utf-8") as f:
        return json.load(f)


def get_required_params(params_schema: dict) -> set:
    return set(params_schema.get("required") or [])


def validate_tool_call(name: str, arguments: dict, schema_by_name: dict) -> list[str]:
    errors = []
    if name not in schema_by_name:
        errors.append(f"Unknown tool: {name}")
        return errors
    tool = schema_by_name[name]
    params = tool.get("parameters") or {}
    props = params.get("properties") or {}
    required = get_required_params(params)
    if not isinstance(arguments, dict):
        errors.append("arguments must be an object")
        return errors
    for r in required:
        if r not in arguments:
            errors.append(f"Missing required argument: {r}")
    for k, v in arguments.items():
        if k not in props:
            continue
        prop = props[k]
        t = prop.get("type")
        if t == "string" and not isinstance(v, str):
            errors.append(f"{k} must be string")
        elif t == "integer" and not isinstance(v, int):
            errors.append(f"{k} must be integer")
        elif t == "boolean" and not isinstance(v, bool):
            errors.append(f"{k} must be boolean")
        elif t == "array" and not isinstance(v, list):
            errors.append(f"{k} must be array")
    return errors


def build_messages_example(user: str, tool_calls: list, system_content: str) -> dict:
    tc_list = [{"name": tc["name"], "arguments": tc.get("arguments") or {}} for tc in tool_calls]
    return {
        "messages": [
            {"role": "system", "content": system_content},
            {"role": "user", "content": user},
            {"role": "assistant", "content": "", "tool_calls": tc_list},
        ]
    }


def load_seeds(path: Path) -> dict | None:
    """Load a seeds JSON file. Keys can be: node_types, scene_paths, script_paths, tools_to_prioritize, extends_classes."""
    if not path or not path.exists():
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (json.JSONDecodeError, OSError):
        return None


def format_seeds_instruction(seeds: dict) -> str:
    """Turn a seeds dict into a short instruction for the model."""
    parts = []
    if seeds.get("node_types"):
        parts.append("node types: " + ", ".join(seeds["node_types"]))
    if seeds.get("extends_classes"):
        parts.append("extends classes: " + ", ".join(seeds["extends_classes"]))
    if seeds.get("scene_paths"):
        parts.append("scenes: " + ", ".join(seeds["scene_paths"]))
    if seeds.get("script_paths"):
        parts.append("script paths: " + ", ".join(seeds["script_paths"]))
    if seeds.get("tools_to_prioritize"):
        parts.append("tools to use in this batch: " + ", ".join(seeds["tools_to_prioritize"]))
    if not parts:
        return ""
    return (
        "\n\nFOCUS for this batch (use these to vary examples; do not duplicate the same tool+key_args in this batch): "
        + "; ".join(parts)
    )


def call_openai(
    tools_schema: list,
    count: int,
    model: str,
    api_key: str,
    batch_seeds: dict | None = None,
) -> list[dict]:
    tools_blob = json.dumps(tools_schema, indent=2)
    user_content = f"Generate exactly {count} diverse training examples. Tools schema:\n{tools_blob}"
    if batch_seeds:
        user_content += format_seeds_instruction(batch_seeds)
    try:
        from openai import OpenAI
    except ImportError:
        sys.stderr.write("Install openai: pip install openai\n")
        sys.exit(1)

    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ],
        temperature=0.7,
    )
    text = (response.choices[0].message.content or "").strip()
    # Strip markdown code block if present
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"API returned invalid JSON: {e}\nRaw:\n{text[:500]}\n")
        return []


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate synthetic tool-use examples via AI")
    parser.add_argument("--count", type=int, default=20, help="Number of examples per API call")
    parser.add_argument("--model", default="gpt-4o", help="OpenAI model (e.g. gpt-4o, gpt-4o-mini)")
    parser.add_argument("--batches", type=int, default=1, help="Number of API calls (total examples ≈ count * batches)")
    parser.add_argument("--system", default="You are a Godot assistant. Use the available tools when needed.", help="System message for each example")
    parser.add_argument(
        "--seeds",
        type=str,
        default="",
        help="JSON file with focus for examples: node_types, scene_paths, script_paths, tools_to_prioritize, extends_classes. Used for every batch.",
    )
    parser.add_argument(
        "--seeds-dir",
        type=str,
        default="",
        help="Directory of JSON seed files; one file per batch (round-robin). Overrides --seeds when set.",
    )
    parser.add_argument(
        "--start-batch",
        type=int,
        default=0,
        help="When using --seeds-dir: start the seed cycle at this batch index (for resuming). E.g. 68 to continue after 68 batches.",
    )
    args = parser.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write("Set OPENAI_API_KEY to use the API.\n")
        sys.exit(1)

    schema = load_schema()
    schema_by_name = {t["name"]: t for t in schema}

    # Resolve seeds: single file or directory (one file per batch)
    seeds_list: list[dict | None] = []
    if args.seeds_dir:
        seeds_dir = REPO_ROOT / args.seeds_dir if not Path(args.seeds_dir).is_absolute() else Path(args.seeds_dir)
        if seeds_dir.is_dir():
            seed_files = sorted(seeds_dir.glob("*.json"))
            seeds_list = [load_seeds(p) for p in seed_files]
        if not seeds_list:
            seeds_list = [None] * args.batches
    elif args.seeds:
        seeds_path = REPO_ROOT / args.seeds if not Path(args.seeds).is_absolute() else Path(args.seeds)
        single = load_seeds(seeds_path)
        seeds_list = [single] * args.batches
    else:
        seeds_list = [None] * args.batches

    SYNTHETIC_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    skipped = 0

    for batch in range(args.batches):
        seed_index = (args.start_batch + batch) % len(seeds_list) if seeds_list else 0
        batch_seeds = seeds_list[seed_index] if seeds_list else None
        raw = call_openai(schema, args.count, args.model, api_key, batch_seeds=batch_seeds)
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
            # Normalize to messages format
            tc_list = []
            for tc in tcs:
                n = tc.get("name") or tc.get("function", {}).get("name")
                args_val = tc.get("arguments")
                if isinstance(args_val, str):
                    args_val = json.loads(args_val) if args_val else {}
                tc_list.append({"name": n, "arguments": args_val or {}})
            record = build_messages_example(user, tc_list, args.system)
            with open(OUTPUT_JSONL, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            written += 1

    print(f"Appended {written} valid examples to {OUTPUT_JSONL} (skipped {skipped})")


if __name__ == "__main__":
    main()
