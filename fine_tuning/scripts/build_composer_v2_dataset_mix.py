#!/usr/bin/env python3
"""
Build a mixed Composer v2 dataset with deterministic 80/20 split.

Reads:
- one or more AGENT JSONL files
- one or more ASK JSONL files

Writes:
- fine_tuning/data/composer_v2/train.jsonl
- fine_tuning/data/composer_v2/val.jsonl

Determinism:
- Mixing selection is deterministic via sha256(user+assistant).
- Train/val split is deterministic via hash modulo threshold (val_ratio).
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]

import sys

sys.path.insert(0, str(REPO_ROOT))
from rag_service.app.prompts import COMPOSER_V2_SYSTEM_PROMPT_AGENT, COMPOSER_V2_SYSTEM_PROMPT_ASK


def _load_jsonl(path: Path) -> Iterable[Dict[str, Any]]:
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            yield json.loads(line)


def _infer_mode(record: Dict[str, Any]) -> Optional[str]:
    messages = record.get("messages") or []
    if not isinstance(messages, list):
        return None
    system_prompt = ""
    assistant = ""
    for m in messages:
        if not isinstance(m, dict):
            continue
        if m.get("role") == "system":
            system_prompt = str(m.get("content") or "")
        elif m.get("role") == "assistant":
            assistant = str(m.get("content") or "")
    if system_prompt == COMPOSER_V2_SYSTEM_PROMPT_AGENT:
        return "agent"
    if system_prompt == COMPOSER_V2_SYSTEM_PROMPT_ASK:
        return "ask"
    if "<tool_call>" in assistant and "</tool_call>" in assistant:
        return "agent"
    if assistant.strip().endswith("?") and "<tool_call>" not in assistant:
        return "ask"
    return None


def _hash_record(user: str, assistant: str) -> int:
    h = hashlib.sha256((user + "\n" + assistant).encode("utf-8")).hexdigest()
    return int(h[:16], 16)


def _extract_user_assistant(record: Dict[str, Any]) -> Tuple[str, str]:
    user = ""
    assistant = ""
    messages = record.get("messages") or []
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        content = str(m.get("content") or "")
        if role == "user":
            user = content
        elif role == "assistant":
            assistant = content
    return user, assistant


def _select_deterministic(records: List[Dict[str, Any]], target_count: int) -> List[Dict[str, Any]]:
    if target_count >= len(records):
        return records
    scored: List[tuple[int, Dict[str, Any]]] = []
    for r in records:
        user, assistant = _extract_user_assistant(r)
        scored.append((_hash_record(user, assistant), r))
    scored.sort(key=lambda t: t[0])
    return [r for _, r in scored[:target_count]]


def _split_train_val(records: List[Dict[str, Any]], val_ratio: float) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    if val_ratio <= 0:
        return records, []
    if val_ratio >= 1:
        return [], records

    # Deterministic split based on hash bucket.
    train: List[Dict[str, Any]] = []
    val: List[Dict[str, Any]] = []
    bucket_mod = 1_000_000
    val_bucket = int(val_ratio * bucket_mod)

    for r in records:
        user, assistant = _extract_user_assistant(r)
        h = _hash_record(user, assistant)
        if (h % bucket_mod) < val_bucket:
            val.append(r)
        else:
            train.append(r)
    return train, val


def main() -> None:
    parser = argparse.ArgumentParser(description="Mix Composer v2 AGENT/ASK datasets deterministically (80/20)")
    parser.add_argument(
        "--agent-files",
        nargs="*",
        default=[
            str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "agent_from_tool_usage.jsonl"),
            str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "agent_from_synthetic_v2_generated.jsonl"),
            str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "agent_generated.jsonl"),
            str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "agent_from_lint_repairs.jsonl"),
        ],
    )
    parser.add_argument(
        "--ask-files",
        nargs="*",
        default=[str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "ask_generated.jsonl")],
    )
    parser.add_argument("--agent-ratio", type=float, default=0.8)
    parser.add_argument("--val-ratio", type=float, default=0.1)
    parser.add_argument("--output-train", type=str, default=str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "train.jsonl"))
    parser.add_argument("--output-val", type=str, default=str(REPO_ROOT / "fine_tuning" / "data" / "composer_v2" / "val.jsonl"))
    args = parser.parse_args()

    agent_records: List[Dict[str, Any]] = []
    ask_records: List[Dict[str, Any]] = []

    for p in args.agent_files:
        path = Path(p)
        if not path.exists():
            continue
        for r in _load_jsonl(path):
            if _infer_mode(r) == "agent":
                agent_records.append(r)

    for p in args.ask_files:
        path = Path(p)
        if not path.exists():
            continue
        for r in _load_jsonl(path):
            if _infer_mode(r) == "ask":
                ask_records.append(r)

    if not agent_records:
        raise SystemExit("No agent records found in provided --agent-files.")
    if not ask_records:
        raise SystemExit("No ask records found in provided --ask-files.")

    agent_ratio = args.agent_ratio
    ask_ratio = 1.0 - agent_ratio

    # Choose the largest total that satisfies both pool sizes under the ratio.
    max_total_by_agent = int(len(agent_records) / agent_ratio) if agent_ratio > 0 else 0
    max_total_by_ask = int(len(ask_records) / ask_ratio) if ask_ratio > 0 else 0
    total_target = min(max_total_by_agent, max_total_by_ask)
    if total_target <= 0:
        raise SystemExit("Invalid ratio or insufficient records to satisfy 80/20 mix.")

    target_agent = int(total_target * agent_ratio)
    target_ask = total_target - target_agent

    selected_agent = _select_deterministic(agent_records, target_agent)
    selected_ask = _select_deterministic(ask_records, target_ask)
    mixed = selected_agent + selected_ask

    train, val = _split_train_val(mixed, args.val_ratio)

    out_train = Path(args.output_train)
    out_val = Path(args.output_val)
    out_train.parent.mkdir(parents=True, exist_ok=True)

    out_train.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in train), encoding="utf-8")
    out_val.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in val), encoding="utf-8")

    print("Composer v2 dataset mix complete.")
    print(f"Agent pool: {len(agent_records)} -> selected: {len(selected_agent)}")
    print(f"Ask pool:   {len(ask_records)} -> selected: {len(selected_ask)}")
    print(f"Total: {len(mixed)} | Train: {len(train)} | Val: {len(val)}")
    print(f"Wrote train: {out_train}")
    print(f"Wrote val:   {out_val}")


if __name__ == "__main__":
    main()

