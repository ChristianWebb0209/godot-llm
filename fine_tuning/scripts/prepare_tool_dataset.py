#!/usr/bin/env python3
"""
Read synthetic (and optional extra) tool-use JSONL, split into train/val, and write
fine_tuning/data/train.jsonl and fine_tuning/data/val.jsonl.

Each input line must be a JSON object with "messages" (array of system/user/assistant
with optional tool_calls on assistant). Output format is the same (one JSON object per line).

Usage (from repo root):
  python fine_tuning/scripts/prepare_tool_dataset.py [--val-ratio 0.1] [--seed 42]
  python fine_tuning/scripts/prepare_tool_dataset.py --include-all --val-ratio 0.1
  python fine_tuning/scripts/prepare_tool_dataset.py --inputs data/synthetic/generated.jsonl godot_knowledge_base/tools_usage/examples.jsonl --val-ratio 0.1

With --include-all: reads all .jsonl (and .json arrays) from fine_tuning/data/synthetic/,
  fine_tuning/data/seeds/, fine_tuning/data/raw/, and godot_knowledge_base/tools_usage/.
"""
import argparse
import json
import random
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
SYNTHETIC_DIR = DATA_DIR / "synthetic"
SEEDS_DIR = DATA_DIR / "seeds"
RAW_DIR = DATA_DIR / "raw"
TOOLS_USAGE_DIR = REPO_ROOT / "godot_knowledge_base" / "tools_usage"
DEFAULT_INPUT = SYNTHETIC_DIR / "generated.jsonl"
TRAIN_OUT = DATA_DIR / "train.jsonl"
VAL_OUT = DATA_DIR / "val.jsonl"

DEFAULT_SOURCE_DIRS = [SYNTHETIC_DIR, SEEDS_DIR, RAW_DIR, TOOLS_USAGE_DIR]

SYSTEM_DEFAULT = "You are a Godot assistant. Use the available tools when needed."


def load_jsonl(path: Path) -> list[dict]:
    out = []
    if not path.exists():
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def load_json_array(path: Path) -> list[dict]:
    """Load a single JSON file that is an array of example objects."""
    if not path.exists():
        return []
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def collect_default_sources() -> list[Path]:
    """Return all JSONL and (array) JSON files from default source dirs.
    In seeds/, only *.jsonl are collected (seeds/*.json are focus configs for generation)."""
    paths: list[Path] = []
    for dir_path in DEFAULT_SOURCE_DIRS:
        if not dir_path.exists():
            continue
        if dir_path == SEEDS_DIR:
            paths.extend(dir_path.glob("*.jsonl"))
        else:
            for ext in ("*.jsonl", "*.json"):
                paths.extend(dir_path.glob(ext))
    return sorted(paths)


def normalize_record(rec: dict) -> dict | None:
    if isinstance(rec.get("messages"), list) and len(rec["messages"]) >= 2:
        return rec
    if "user" in rec and "tool_calls" in rec:
        return {
            "messages": [
                {"role": "system", "content": SYSTEM_DEFAULT},
                {"role": "user", "content": rec["user"]},
                {"role": "assistant", "content": "", "tool_calls": rec["tool_calls"]},
            ],
        }
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Build train/val JSONL from synthetic and optional inputs")
    parser.add_argument(
        "--inputs",
        nargs="*",
        default=None,
        help="Input JSONL/JSON paths (relative to repo root or absolute). If omitted and not --include-all, use fine_tuning/data/synthetic/generated.jsonl only.",
    )
    parser.add_argument(
        "--include-all",
        action="store_true",
        help="Gather from synthetic/, seeds/, raw/, and godot_knowledge_base/tools_usage/ (all .jsonl and .json)",
    )
    parser.add_argument("--val-ratio", type=float, default=0.1, help="Fraction of examples for validation (0–1)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for shuffle")
    args = parser.parse_args()

    input_paths: list[Path] = []
    if args.include_all:
        input_paths = collect_default_sources()
        if not input_paths:
            sys.stderr.write("--include-all: no JSONL/JSON files found in default source dirs.\n")
            sys.exit(1)
    elif args.inputs:
        for raw_path in args.inputs:
            p = Path(raw_path)
            if not p.is_absolute():
                p = REPO_ROOT / p
            input_paths.append(p)
    else:
        input_paths = [DEFAULT_INPUT]

    examples: list[dict] = []
    for path in input_paths:
        if not path.exists():
            continue
        if path.suffix.lower() == ".jsonl":
            records = load_jsonl(path)
        else:
            records = load_json_array(path)
        for rec in records:
            if not isinstance(rec, dict):
                continue
            normalized = normalize_record(rec)
            if normalized:
                examples.append(normalized)

    if not examples:
        sys.stderr.write(
            "No valid examples found. Add JSONL to synthetic/, seeds/, raw/, or godot_knowledge_base/tools_usage/, "
            "or pass --inputs or --include-all.\n"
        )
        sys.exit(1)

    random.seed(args.seed)
    random.shuffle(examples)
    n_val = max(1, int(len(examples) * args.val_ratio))
    n_train = len(examples) - n_val
    train_examples = examples[:n_train]
    val_examples = examples[n_train:]

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(TRAIN_OUT, "w", encoding="utf-8") as f:
        for rec in train_examples:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    with open(VAL_OUT, "w", encoding="utf-8") as f:
        for rec in val_examples:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print(f"Wrote {len(train_examples)} train -> {TRAIN_OUT}")
    print(f"Wrote {len(val_examples)} val   -> {VAL_OUT}")


if __name__ == "__main__":
    main()
