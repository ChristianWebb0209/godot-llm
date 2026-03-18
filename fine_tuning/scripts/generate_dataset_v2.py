#!/usr/bin/env python3
"""
Generate a V2 tool-calling dataset for Godot LLM fine-tuning.
Unlike standard function calling formats, this forcefully trains the model to emit
XML-style <tool_call> tags directly inside the assistant's `content` stream.

Features:
- Reads tools from fine_tuning/schemas/tools.json
- Automatically seeds batches (node_types, styles, tools) for high diversity
- Generates Tool-use (~60%), Negative (~20%), and Sharp Synthetic (~20%) based on ratio arguments
- Validates the XML format directly

Usage:
  python fine_tuning/scripts/generate_dataset_v2.py --count 100 --batches 10
"""
import argparse
import concurrent.futures
import json
import os
import random
import re
import sys
import threading
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

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
OUTPUT_JSONL = SYNTHETIC_DIR / "v2_generated.jsonl"

# --- Dynamic Seed Pools ---
NODE_TYPES = ["Node2D", "CharacterBody2D", "Sprite2D", "Node3D", "CharacterBody3D", "MeshInstance3D", "Control", "Button", "Label", "Area2D", "RigidBody2D", "CollisionShape2D", "Camera2D", "AnimationPlayer"]
SCENE_PATHS = ["res://main.tscn", "res://player.tscn", "res://enemy.tscn", "res://level_1.tscn", "res://ui/hud.tscn"]
SCRIPT_PATHS = ["res://scripts/player.gd", "res://scripts/enemy.gd", "res://scripts/game_manager.gd", "res://ui/hud.gd", "res://autoloads/events.gd"]
EXTENDS_CLASSES = ["Node", "Node2D", "CharacterBody2D", "Control", "Resource", "RefCounted"]
STYLES = ["concise", "casual", "technical", "beginner", "directive"]

# We will collect available tools dynamically below.

# --- Prompts ---
SYSTEM_PROMPT = """You are generating training examples for a Godot 4.x coding assistant that uses tools.
You will be given a JSON array of tool definitions.
You must output a JSON array of conversational objects. Each object MUST have exactly these two keys:
  "user": <string> - a realistic user prompt or question regarding Godot.
  "assistant": <string> - the raw text response from the assistant.

CRITICAL XML TOOL FORMAT:
When the assistant uses a tool, it MUST NOT output conversational text, and it MUST NOT use a native JSON `tool_calls` dictionary field.
Instead, it MUST emit exactly one or more XML blocks directly inside the "assistant" string:

<tool_call>
{{"name": "<exact tool name>", "arguments": {{ ... }}}}
</tool_call>

"arguments" MUST be a dictionary (not a string).

Rules:
- 1 user message triggers 1 or multiple <tool_call> tags.
- Use only the tools provided in the schema. Do not hallucinate tools.
- Output ONLY a JSON array of these objects, no markdown wrappers.
- {directive}
"""

def load_schema() -> list:
    if not TOOLS_JSON.exists():
        sys.stderr.write(f"Schema not found: {TOOLS_JSON}\n")
        sys.exit(1)
    with open(TOOLS_JSON, encoding="utf-8") as f:
        return json.load(f)

def generate_batch_seed(available_tools: list, tool_counts: dict) -> dict:
    """Generate a random blend of constraints for this batch, prioritizing lowest used tools."""
    sorted_tools = sorted(available_tools, key=lambda t: tool_counts.get(t, 0))
    pool_size = max(4, len(sorted_tools) // 2)
    lowest_used_pool = sorted_tools[:pool_size]
    
    return {
        "node_types": random.sample(NODE_TYPES, k=random.randint(1, 3)),
        "scene_paths": random.sample(SCENE_PATHS, k=random.randint(0, 2)),
        "tools_to_prioritize": random.sample(lowest_used_pool, k=min(random.randint(2, 3), len(lowest_used_pool))) if lowest_used_pool else [],
        "style": random.choice(STYLES)
    }

def format_seeds_instruction(seeds: dict) -> str:
    parts = []
    if seeds.get("node_types"): parts.append("nodes: " + ", ".join(seeds["node_types"]))
    if seeds.get("scene_paths"): parts.append("scenes: " + ", ".join(seeds["scene_paths"]))
    if seeds.get("tools_to_prioritize"): parts.append("tools to prioritize: " + ", ".join(seeds["tools_to_prioritize"]))
    if seeds.get("style"): parts.append(f"Prompt style tone: {seeds['style']}")
    
    if not parts: return ""
    return "\nFOCUS for this batch (vary examples drastically using these constraints, do NOT repeat the same tool arguments twice): " + "; ".join(parts)

def call_openai_v2(
    tools_schema: list,
    count: int,
    model: str,
    api_key: str,
    mode: str, # "tool", "sharp", "negative"
    batch_seeds: dict | None = None
) -> list[dict]:
    try:
        from openai import OpenAI
    except ImportError:
        sys.stderr.write("Install openai: pip install openai\n")
        sys.exit(1)

    tools_blob = json.dumps(tools_schema, indent=2)
    user_content = f"Generate exactly {count} examples. Tools schema:\n{tools_blob}"
    if batch_seeds:
        user_content += format_seeds_instruction(batch_seeds)

    if mode == "negative":
        directive = (
            "These are NEGATIVE examples. The user asks general Godot questions that DO NOT require tools "
            "(e.g., 'What is a Node?', 'Explain _process'). The assistant provides a helpful short text "
            "explanation WITHOUT ANY <tool_call> tags. "
            "Include cases that might seem tool-worthy but are actually conceptual or general questions. "
            "Ensure the assistant never emits a <tool_call> block."
        )
    elif mode == "sharp":
        directive = (
            "These are SHARP positive examples. The user gives short, unambiguous imperative commands "
            "(e.g., 'Read player.gd'). The assistant executes the single corresponding XML <tool_call> "
            "and nothing else. No conversational padding. "
            "Include cases where similar requests require different tools. Ensure the assistant selects the correct one."
        )   
    elif mode == "borderline":
        directive = (
            "These are BORDERLINE examples. Some user requests MAY or MAY NOT require tools. "
            "The assistant must decide correctly. If a tool is clearly needed, use <tool_call>. "
            "If not, respond with a normal explanation and NO <tool_call> tag. "
            "Include cases where similar requests require different tools or no tool at all. "
            "Ensure the assistant selects the correct behavior."
        )
    else: # basic tool
        directive = (
            "These are STANDARD positive examples. The user asks about their project. "
            "The assistant executes a relevant XML <tool_call> and nothing else. No conversational padding. "
            "Include cases where similar requests require different tools. Ensure the assistant selects the correct one."
        )
    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT.format(directive=directive)},
            {"role": "user", "content": user_content},
        ],
        temperature=0.7,
        max_tokens=4000,
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

def validate_xml_tool_call(assistant_content: str, schema_by_name: dict, mode: str) -> tuple[bool, str]:
    """Validate that the given assistant content properly implements the <tool_call> XML rules."""
    stripped = assistant_content.strip()
    has_tag = "<tool_call>" in stripped
    
    if mode == "negative":
        # Negatives should NOT have tool calls
        if has_tag:
            return False, "has_tool_call_in_negative"
        return True, ""
        
    if not has_tag:
        if mode == "borderline":
            if len(stripped) < 20: 
                return False, "borderline_too_short"
            return True, ""
        return False, "missing_tool_call"
        
    if mode not in ("negative", "borderline"):
        if not stripped.startswith("<tool_call>") or not stripped.endswith("</tool_call>"):
            return False, "extra_text_outside_tool_call"

    # Extract all JSON contents inside <tool_call> blocks
    blocks = re.findall(r"<tool_call>\s*(.*?)\s*</tool_call>", assistant_content, re.DOTALL)
    if not blocks:
        return False, "malformed_xml"

    for block in blocks:
        try:
            call_dict = json.loads(block)
        except json.JSONDecodeError:
            return False, "bad_json"
            
        name = call_dict.get("name")
        args = call_dict.get("arguments")
        
        if not name or name not in schema_by_name:
            return False, "schema_fail_unknown_tool"
        if not isinstance(args, dict): # MUST be a dict, not string
            return False, "schema_fail_bad_args"
            
        # Basic required param check
        tool_schema = schema_by_name[name]
        required = tool_schema.get("parameters", {}).get("required", [])
        for req in required:
            if req not in args:
                return False, "missing_required_args"

    return True, ""

def build_final_record(user: str, assistant: str, system_default: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": system_default},
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant}
        ]
    }

def main():
    parser = argparse.ArgumentParser(description="Generate V2 Dataset with XML Tools")
    parser.add_argument("--count", type=int, default=50, help="Examples per batch")
    parser.add_argument("--batches", type=int, default=10, help="Number of API batches")
    parser.add_argument("--model", default="gpt-4o", help="OpenAI Model")
    parser.add_argument("--system", default="You are a Godot assistant. Use the available tools when needed.", help="System message written into output records")
    # Proportions
    parser.add_argument("--ratio-tools", type=float, default=0.5)
    parser.add_argument("--ratio-sharp", type=float, default=0.2)
    parser.add_argument("--ratio-negative", type=float, default=0.2)
    parser.add_argument("--ratio-borderline", type=float, default=0.1)
    args = parser.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write("Set OPENAI_API_KEY to use the API.\n")
        sys.exit(1)

    schema = load_schema()
    schema_by_name = {t["name"]: t for t in schema}
    available_tool_names = list(schema_by_name.keys())

    SYNTHETIC_DIR.mkdir(parents=True, exist_ok=True)
    
    written = 0
    skipped = 0

    total_ratio = args.ratio_tools + args.ratio_sharp + args.ratio_negative + args.ratio_borderline
    # Normalize ratios if they don't exactly add to 1.0
    r_tool = args.ratio_tools / total_ratio
    r_sharp = args.ratio_sharp / total_ratio
    r_neg = args.ratio_negative / total_ratio
    r_bord = args.ratio_borderline / total_ratio

    modes_plan = (
        ["tool"] * int(args.batches * r_tool) +
        ["sharp"] * int(args.batches * r_sharp) +
        ["negative"] * int(args.batches * r_neg) +
        ["borderline"] * int(args.batches * r_bord)
    )
    # Fill remaining slots if rounding truncation occurred
    while len(modes_plan) < args.batches:
        modes_plan.append("tool")
        
    random.shuffle(modes_plan)

    print(f"Starting {args.batches} batches of {args.count} examples with ThreadPoolExecutor...")
    seen = set()
    fail_reasons = {}
    tool_counts = {name: 0 for name in available_tool_names}
    
    lock = threading.Lock()

    def process_batch(batch_idx):
        nonlocal written, skipped
        mode = modes_plan[batch_idx]

        attempts = 0
        batch_written = 0
        
        while attempts < 3 and batch_written < (args.count * 0.6):
            attempts += 1
            with lock:
                seed = generate_batch_seed(available_tool_names, tool_counts)
            
            print(f"Batch {batch_idx+1}/{args.batches} (Attempt {attempts}) | Mode: {mode.upper()} | Style: {seed.get('style')}")

            raw = call_openai_v2(schema, args.count, args.model, api_key, mode, seed)
            if not isinstance(raw, list):
                raw = [raw] if raw else []
                
            for item in raw:
                user = item.get("user")
                assistant = item.get("assistant")
                if not user or not assistant:
                    with lock:
                        skipped += 1
                    continue
                    
                key = (str(user).strip(), str(assistant).strip())
                with lock:
                    if key in seen:
                        skipped += 1
                        fail_reasons["duplicate"] = fail_reasons.get("duplicate", 0) + 1
                        continue
                    seen.add(key)
                    
                is_valid, reason = validate_xml_tool_call(assistant, schema_by_name, mode)
                
                with lock:
                    if is_valid:
                        # Update tool usage counts
                        for block in re.findall(r"<tool_call>\s*(.*?)\s*</tool_call>", assistant, re.DOTALL):
                            try:
                                name = json.loads(block).get("name")
                                if name:
                                    tool_counts[name] = tool_counts.get(name, 0) + 1
                            except: pass
                            
                        record = build_final_record(user, assistant, args.system)
                        with open(OUTPUT_JSONL, "a", encoding="utf-8") as f:
                            f.write(json.dumps(record, ensure_ascii=False) + "\n")
                        written += 1
                        batch_written += 1
                    else:
                        skipped += 1
                        fail_reasons[reason] = fail_reasons.get(reason, 0) + 1

            if batch_written >= (args.count * 0.6):
                break
            else:
                print(f"  -> Batch {batch_idx+1} only got {batch_written} valid examples. Retrying...")

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        futures = {executor.submit(process_batch, i): i for i in range(args.batches)}
        for future in concurrent.futures.as_completed(futures):
            b_idx = futures[future]
            try:
                future.result()
            except Exception as e:
                print(f"Batch {b_idx+1} failed with exception: {e}")

    print(f"\nFinished! Appended {written} validated V2 XML examples to {OUTPUT_JSONL}")
    print(f"Skipped {skipped} poorly formatted/duplicate examples.")
    if fail_reasons:
        print("Failure breakdown:")
        for reason, c in sorted(fail_reasons.items(), key=lambda x: -x[1]):
            print(f"  {reason}: {c}")

if __name__ == "__main__":
    main()
