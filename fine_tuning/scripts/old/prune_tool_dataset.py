#!/usr/bin/env python3
"""
Prune a tool-use dataset by removing bad examples:
- Examples with malformed JSON
- Examples where tool definitions have string 'arguments' instead of objects
- Examples where the assistant rambles before calling tools (content > 50 chars)
- Examples with unknown tools (if schema is provided or just basic structure validation)

Usage:
  python fine_tuning/scripts/prune_tool_dataset.py --input fine_tuning/data/tool_usage/train.jsonl --output fine_tuning/data/tool_usage/train_pruned.jsonl
"""
import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

def is_valid_record(record: dict, max_assistant_content_len: int = 50) -> bool:
    messages = record.get("messages")
    if not isinstance(messages, list):
        return False
    
    has_assistant = False
    for msg in messages:
        if not isinstance(msg, dict):
            return False
            
        role = msg.get("role")
        if role == "assistant":
            has_assistant = True
            content = msg.get("content") or ""
            
            tool_calls = msg.get("tool_calls")
            if tool_calls:
                # If there are tool calls, ensure content is crisp/short to prevent rambling
                if len(content.strip()) > max_assistant_content_len:
                    return False
                
                if not isinstance(tool_calls, list):
                    return False
                    
                for tc in tool_calls:
                    if not isinstance(tc, dict):
                        return False
                    name = tc.get("name")
                    if not name or not isinstance(name, str):
                        return False
                    
                    args = tc.get("arguments")
                    # Arguments MUST be a dict/object, not a string
                    if not isinstance(args, dict):
                        return False

    # We only care about pruning records that have at least one valid assistant message.
    return has_assistant

def main() -> None:
    parser = argparse.ArgumentParser(description="Prune noisy/bad records from a tool-use dataset.")
    parser.add_argument("--input", type=str, required=True, help="Input JSONL file")
    parser.add_argument("--output", type=str, required=True, help="Output JSONL file")
    parser.add_argument("--max-content-len", type=int, default=50, help="Max characters for assistant content when tool_calls are present")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.is_absolute():
        input_path = REPO_ROOT / input_path
        
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = REPO_ROOT / output_path

    if not input_path.exists():
        sys.stderr.write(f"Input file not found: {input_path}\n")
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    kept = 0
    discarded = 0
    total = 0

    with open(input_path, "r", encoding="utf-8") as f_in, \
         open(output_path, "w", encoding="utf-8") as f_out:
        
        for line in f_in:
            line = line.strip()
            if not line:
                continue
            
            total += 1
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                discarded += 1
                continue
                
            if is_valid_record(record, args.max_content_len):
                f_out.write(json.dumps(record, ensure_ascii=False) + "\n")
                kept += 1
            else:
                discarded += 1

    print(f"Pruning complete for {input_path.name}:")
    print(f"  Total processed: {total}")
    print(f"  Kept:            {kept} ({kept/total*100:.1f}%)" if total else "Kept: 0")
    print(f"  Discarded:       {discarded} ({discarded/total*100:.1f}%)" if total else "Discarded: 0")
    print(f"Output saved to:   {output_path}")

if __name__ == "__main__":
    main()
