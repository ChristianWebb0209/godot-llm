#!/usr/bin/env python3
"""
Prepare docs Q&A-style JSONL from scraped Godot docs.

Input:
  - godot_knowledge_base/docs/** (Markdown files produced by docs-parser scripts)

Output:
  - fine_tuning/data/docs_qa/docs_qa.jsonl

Each line is a JSON object in messages format:
  {
    "messages": [
      {"role": "system", "content": "You are a Godot assistant. Answer using the provided docs snippet."},
      {"role": "user", "content": "Show the documentation snippet for res://docs/4.x/classes/class_camera3d.md"},
      {"role": "assistant", "content": "# Camera3D\\n... full or truncated docs markdown ..." }
    ]
  }

This keeps the docs content verbatim as the assistant answer; your training
pipeline can later mix these with tool-use and code-style data.
"""
import argparse
import sys
from pathlib import Path
import json

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS_ROOT = REPO_ROOT / "godot_knowledge_base" / "docs"
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
OUT_DIR = DATA_DIR / "docs_qa"
OUT_PATH = OUT_DIR / "docs_qa.jsonl"

SYSTEM_DEFAULT = "You are a Godot assistant. Answer using the provided docs snippet."


def iter_docs(max_files: int | None = None):
    """Yield (rel_path, content) for .md files under DOCS_ROOT."""
    if not DOCS_ROOT.exists():
        return
    count = 0
    for p in sorted(DOCS_ROOT.rglob("*.md")):
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        rel = p.relative_to(DOCS_ROOT)
        yield rel, text
        count += 1
        if max_files is not None and count >= max_files:
            break


def main() -> None:
    parser = argparse.ArgumentParser(description="Build docs Q&A JSONL from godot_knowledge_base/docs")
    parser.add_argument(
        "--max-files",
        type=int,
        default=2000,
        help="Optional cap on number of docs files to convert (0 = no cap).",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        default=6000,
        help="Approximate cap on characters per snippet to avoid extremely long samples.",
    )
    args = parser.parse_args()

    if not DOCS_ROOT.exists():
        sys.stderr.write(f"Docs root not found at {DOCS_ROOT}. Run the docs-parser scripts first.\n")
        sys.exit(0)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    max_files = args.max_files if args.max_files and args.max_files > 0 else None
    max_chars = args.max_chars if args.max_chars and args.max_chars > 0 else None

    with open(OUT_PATH, "w", encoding="utf-8") as out_f:
        for rel_path, text in iter_docs(max_files=max_files):
            snippet = text
            if max_chars is not None and len(snippet) > max_chars:
                snippet = snippet[: max_chars] + "\n\n...(truncated)..."
            user_content = f"Show the documentation snippet for `{rel_path.as_posix()}`."
            rec = {
                "messages": [
                    {"role": "system", "content": SYSTEM_DEFAULT},
                    {"role": "user", "content": user_content},
                    {"role": "assistant", "content": snippet},
                ]
            }
            out_f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            written += 1

    print(f"Wrote {written} docs Q&A examples to {OUT_PATH}")


if __name__ == "__main__":
    main()

