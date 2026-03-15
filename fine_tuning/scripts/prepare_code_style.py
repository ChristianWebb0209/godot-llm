#!/usr/bin/env python3
"""
Prepare code-style data from scraped repos into JSONL.

Input:
  - godot_knowledge_base/scraped_repos/index/master.json
  - godot_knowledge_base/scraped_repos/<ExtendsClass>/<Owner_Repo__path__file.ext>

Output:
  - fine_tuning/data/code_completion/code_style.jsonl

Each line is a JSON object:
  {
    "path": "CharacterBody2D/Repo__path__Player.gd",
    "extends_class": "CharacterBody2D",
    "language": "gdscript",
    "tags": [...],
    "role": "...",
    "importance": 0.8,
    "code": "extends CharacterBody2D\n..."
  }

This is intentionally simple and lossless; your training pipeline or a later
prep step can convert this into whatever format your framework expects
(messages, input/output pairs, etc.).
"""
import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRAPED_ROOT = REPO_ROOT / "godot_knowledge_base" / "scraped_repos"
INDEX_PATH = SCRAPED_ROOT / "index" / "master.json"
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
OUT_DIR = DATA_DIR / "code_completion"
OUT_PATH = OUT_DIR / "code_style.jsonl"


def main() -> None:
    parser = argparse.ArgumentParser(description="Build code-style JSONL from scraped_repos")
    parser.add_argument(
        "--max-files",
        type=int,
        default=5000,
        help="Optional cap on number of scraped files to include (for sanity). 0 = no cap.",
    )
    args = parser.parse_args()

    if not INDEX_PATH.exists():
        sys.stderr.write(f"Index not found at {INDEX_PATH}. Run the project-scraper first.\n")
        sys.exit(0)

    try:
        with open(INDEX_PATH, encoding="utf-8") as f:
            entries = json.load(f)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"Failed to parse {INDEX_PATH}: {e}\n")
        sys.exit(1)

    if not isinstance(entries, list):
        sys.stderr.write(f"{INDEX_PATH} did not contain a JSON array.\n")
        sys.exit(1)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    max_files = args.max_files if args.max_files and args.max_files > 0 else None

    with open(OUT_PATH, "w", encoding="utf-8") as out_f:
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            # Expected keys per DATA-FORMAT.md / scraper: path, rel_path, extends_class, component_type,
            # role, language, tags, importance, description.
            path_rel = entry.get("path") or entry.get("rel_path")
            if not path_rel:
                continue
            abs_path = SCRAPED_ROOT / path_rel
            if not abs_path.exists():
                # Try extends_class + rel_path if path is only the filename.
                ext_cls = entry.get("extends_class") or ""
                if ext_cls:
                    alt = SCRAPED_ROOT / ext_cls / str(path_rel)
                    if alt.exists():
                        abs_path = alt
                    else:
                        continue
                else:
                    continue
            try:
                code = abs_path.read_text(encoding="utf-8")
            except OSError:
                continue
            rec = {
                "path": str(path_rel),
                "extends_class": entry.get("extends_class"),
                "language": entry.get("language"),
                "tags": entry.get("tags") or [],
                "role": entry.get("role"),
                "importance": entry.get("importance"),
                "description": entry.get("description"),
                "code": code,
            }
            out_f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            written += 1
            if max_files is not None and written >= max_files:
                break

    print(f"Wrote {written} code-style examples to {OUT_PATH}")


if __name__ == "__main__":
    main()

