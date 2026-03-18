#!/usr/bin/env python3
"""
Remove tool_usage examples that call search_docs, search_project_code, or request_component_context
(these tools were removed from the assistant). Run before training so the model is not taught removed tools.

Usage (from repo root):
  python fine_tuning/scripts/filter_removed_tools.py

Reads fine_tuning/data/tool_usage/train.jsonl, val.jsonl, tool_usage.jsonl; writes the same paths
with only lines where no tool_calls use the removed tools. Backs up originals to .bak.
"""
from pathlib import Path
import json
import shutil

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "fine_tuning" / "data" / "tool_usage"
REMOVED = {"search_docs", "search_project_code", "request_component_context"}

FILES = ["train.jsonl", "val.jsonl", "tool_usage.jsonl"]


def line_uses_removed_tools(line: str) -> bool:
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return True  # keep malformed lines, let training fail elsewhere
    messages = data.get("messages") or []
    for msg in messages:
        for tc in msg.get("tool_calls") or []:
            if (tc.get("name") or "").strip() in REMOVED:
                return True
    return False


def main() -> None:
    for name in FILES:
        path = DATA_DIR / name
        if not path.exists():
            print(f"Skip (not found): {path}")
            continue
        backup = path.with_suffix(path.suffix + ".bak")
        shutil.copy2(path, backup)
        kept = 0
        dropped = 0
        with open(path, "r", encoding="utf-8") as f:
            lines = [ln.strip() for ln in f if ln.strip()]
        with open(path, "w", encoding="utf-8") as out:
            for ln in lines:
                if line_uses_removed_tools(ln):
                    dropped += 1
                    continue
                out.write(ln + "\n")
                kept += 1
        print(f"{name}: kept {kept}, dropped {dropped} (backup: {backup.name})")


if __name__ == "__main__":
    main()
