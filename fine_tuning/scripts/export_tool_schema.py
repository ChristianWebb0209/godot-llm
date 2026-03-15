#!/usr/bin/env python3
"""
Export tool definitions from rag_service to fine_tuning/schemas/tools.json.
Run from repo root (with rag_service deps installed, e.g. pip install -r rag_service/requirements.txt):
  python fine_tuning/scripts/export_tool_schema.py
"""
from pathlib import Path
import json
import sys

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMAS_DIR = REPO_ROOT / "fine_tuning" / "schemas"
OUTPUT_FILE = SCHEMAS_DIR / "tools.json"


def main() -> None:
    sys.path.insert(0, str(REPO_ROOT))
    # Allow importing from rag_service
    rag = REPO_ROOT / "rag_service"
    if not rag.exists():
        sys.stderr.write("rag_service not found at repo root\n")
        sys.exit(1)
    sys.path.insert(0, str(rag))

    try:
        from app.services.tools import get_registered_tools
    except ImportError as e:
        sys.stderr.write(
            f"Could not import rag_service app ({e}). "
            "Install deps from repo root: pip install -r rag_service/requirements.txt\n"
        )
        sys.exit(1)

    tools = get_registered_tools()
    payload = []
    for t in tools:
        payload.append({
            "name": t.name,
            "description": t.description,
            "parameters": t.parameters,
        })

    SCHEMAS_DIR.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    print(f"Exported {len(payload)} tools to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
