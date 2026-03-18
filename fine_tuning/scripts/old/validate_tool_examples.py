#!/usr/bin/env python3
"""
Validate that tool_usage JSONL files only reference tools present in schemas/tools.json.
Run before training to ensure no references to removed tools (e.g. search_docs) remain.

Usage (from repo root):
  python fine_tuning/scripts/validate_tool_examples.py
"""
from pathlib import Path
import json
import sys

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "fine_tuning" / "data" / "tool_usage"
SCHEMA_FILE = REPO_ROOT / "fine_tuning" / "schemas" / "tools.json"

FILES = ["train.jsonl", "val.jsonl", "tool_usage.jsonl"]


def main() -> int:
    if not SCHEMA_FILE.exists():
        sys.stderr.write(f"Schema not found: {SCHEMA_FILE}\n")
        return 1
    with open(SCHEMA_FILE, "r", encoding="utf-8") as f:
        schema = json.load(f)
    allowed = {t["name"] for t in schema}
    errors = []
    for name in FILES:
        path = DATA_DIR / name
        if not path.exists():
            continue
        with open(path, "r", encoding="utf-8") as f:
            for i, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    errors.append((path.name, i, "Invalid JSON", line[:80]))
                    continue
                for msg in data.get("messages") or []:
                    for tc in msg.get("tool_calls") or []:
                        tool_name = (tc.get("name") or "").strip()
                        if tool_name and tool_name not in allowed:
                            errors.append((path.name, i, f"Unknown tool: {tool_name}", line[:80]))
    if errors:
        for file_name, line_no, msg, preview in errors:
            sys.stderr.write(f"{file_name}:{line_no} {msg}\n  {preview}...\n")
        sys.stderr.write(f"Total {len(errors)} error(s). Fix or filter these lines before training.\n")
        return 1
    print("OK: all tool_calls reference tools in schemas/tools.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
