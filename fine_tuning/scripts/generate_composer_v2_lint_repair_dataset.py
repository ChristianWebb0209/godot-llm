#!/usr/bin/env python3
"""
Generate Composer v2 AGENT-mode training examples for Lint-Repair.

Each example represents the runtime's lint-repair follow-up step:
- The user provides:
  - the (broken) current file content
  - lint output (from Godot linter)
  - the active script path
- The assistant emits ONLY XML <tool_call> blocks (Composer v2 AGENT contract)
  that fix the lint errors.

Key property: this script validates "broken_code fails lint" and
"fixed_code passes lint" using `rag_service/scripts/gdlint.ps1` by temporarily
writing scripts under `godot_plugin/scripts/`.

This produces high-quality, non-hallucinated lint output for training.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from rag_service.app.prompts import COMPOSER_V2_SYSTEM_PROMPT_AGENT


TOOLS_JSON = REPO_ROOT / "fine_tuning" / "schemas" / "tools.json"
DATA_DIR = REPO_ROOT / "fine_tuning" / "data" / "composer_v2"

# Where we can create temporary .gd files for real lint validation.
GODOT_PLUGIN_SCRIPTS_DIR = REPO_ROOT / "godot_plugin" / "scripts"

# Load API keys/settings for OpenAI generation when available.
try:
    from dotenv import load_dotenv

    load_dotenv(REPO_ROOT / ".env")
    load_dotenv(REPO_ROOT / "fine_tuning" / ".env", override=True)
except Exception:
    pass


@dataclass
class LintRun:
    ok: bool
    raw_output: str
    lint_output: str


def _load_tools_schema() -> List[Dict[str, Any]]:
    if not TOOLS_JSON.exists():
        raise SystemExit(f"tools schema not found: {TOOLS_JSON}")
    return json.loads(TOOLS_JSON.read_text(encoding="utf-8"))


def _extract_lint_output_relevant(raw: str) -> str:
    """
    gdlint.ps1 includes additional noisy engine shutdown warnings about leaked RIDs.
    We keep only the part around the actual SCRIPT ERROR / parse error.
    """
    if not raw:
        return ""

    lines = raw.splitlines()
    start_idx = None
    for i, line in enumerate(lines):
        if "SCRIPT ERROR:" in line or "Parse Error:" in line:
            start_idx = i
            break

    if start_idx is None:
        # Fall back: include all lines that look like Godot lint/errors.
        keep: List[str] = []
        for line in lines:
            if "SCRIPT ERROR" in line or "Parse Error" in line:
                keep.append(line)
            elif line.startswith("ERROR:") and "RID allocations" not in line and "ObjectDB" not in line:
                keep.append(line)
            elif line.strip().startswith("at:") and keep:
                keep.append(line)
        return "\n".join(keep).strip()

    stop_markers = (
        "WARNING: 1 RID",
        "ERROR: 1 RID",
        "WARNING: 17 ObjectDB",
        "gdlint: ok",
        "gdlint: issues found",
    )

    kept: List[str] = []
    for j in range(start_idx, len(lines)):
        line = lines[j]
        if any(line.startswith(m) for m in stop_markers):
            break
        kept.append(line)

    return "\n".join(kept).strip()


def run_gdlint_on_plugin_script(res_rel_path: str) -> LintRun:
    """
    res_rel_path should be something like:
      res://scripts/my_tmp.gd
    """
    # Convert to absolute path inside repo, because gdlint.ps1 resolves relative to rag_service.
    # We will pass a path like ..\godot_plugin\scripts\my_tmp.gd
    if not res_rel_path.startswith("res://"):
        raise ValueExitError("res_rel_path must start with res://")

    # In this repo, `res://` is rooted at `godot_plugin/` (see rag_service/scripts/gdlint.ps1).
    rel = res_rel_path[len("res://") :]
    abs_path = REPO_ROOT / "godot_plugin" / rel
    if not abs_path.exists():
        return LintRun(ok=False, raw_output="", lint_output="File not found in lint runner.")

    # gdlint.ps1 is executed from rag_service/ and expects paths relative to repo root.
    # So for `res://scripts/x.gd` we need: ..\godot_plugin\scripts\x.gd
    gd_file_rel_from_rag_service = Path("..") / "godot_plugin" / rel
    cmd = (
        f"cd rag_service; "
        f".\\scripts\\gdlint.ps1 -Files \"{gd_file_rel_from_rag_service.as_posix()}\""
    )
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-Command", cmd],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    raw = (proc.stdout or "") + (proc.stderr or "")
    ok = proc.returncode == 0
    lint_output = _extract_lint_output_relevant(raw)
    return LintRun(ok=ok, raw_output=raw, lint_output=lint_output)


class JSONParseError(RuntimeError):
    pass


def _safe_json_loads(text: str) -> Any:
    s = (text or "").strip()
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    try:
        return json.loads(s)
    except json.JSONDecodeError as e:
        raise JSONParseError(f"OpenAI returned invalid JSON: {e}. Raw head: {s[:500]}")


def _corrupt_code_to_create_parse_error(fixed_code: str) -> Optional[str]:
    """
    Corrupt a known marker line to make it fail parse:
    - Find the line containing "# __LINT_TARGET__"
    - Remove the ':' that terminates the function signature, i.e. just
      before the comment marker.
    """
    lines = fixed_code.splitlines()
    for i, line in enumerate(lines):
        if "__LINT_TARGET__" in line:
            marker_idx = line.find("# __LINT_TARGET__")
            if marker_idx == -1:
                return None
            prefix = line[:marker_idx].rstrip()
            suffix = line[marker_idx:]  # includes '# __LINT_TARGET__'
            if not prefix.endswith(":"):
                return None
            prefix_wo_colon = prefix[:-1].rstrip()
            # Preserve a single space before the comment when appropriate.
            if prefix_wo_colon and not prefix_wo_colon.endswith(" "):
                prefix_wo_colon += " "
            lines[i] = prefix_wo_colon + suffix.lstrip()
            return "\n".join(lines) + "\n"
    return None


def _build_user_content(broken_code: str, lint_output: str, active_script_path: str) -> str:
    # Must mirror rag_service composer runtime labels closely.
    return (
        "Fix the remaining lint errors in this file.\n\n"
        "Current file content:\n"
        f"{broken_code}\n\n"
        "Lint output:\n"
        f"{lint_output}\n\n"
        "Active script:\n"
        f"{active_script_path}\n"
    )


def _build_assistant_tool_call_write_file(path: str, content: str) -> str:
    inner = {"name": "write_file", "arguments": {"path": path, "content": content}}
    inner_json = json.dumps(inner, ensure_ascii=False)
    return f"<tool_call>{inner_json}</tool_call>"


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Composer v2 lint-repair AGENT JSONL")
    parser.add_argument("--output", type=str, default=str(DATA_DIR / "agent_from_lint_repairs.jsonl"))
    parser.add_argument("--count", type=int, default=50, help="Valid examples to generate")
    parser.add_argument("--batches", type=int, default=10, help="Max OpenAI calls (upper bound)")
    parser.add_argument("--candidates-per-batch", type=int, default=10, help="Fixed-code candidates per OpenAI batch")
    parser.add_argument("--model", type=str, default=os.getenv("OPENAI_MODEL", "gpt-4o-mini"))
    parser.add_argument("--temperature", type=float, default=0.4)
    parser.add_argument("--max-tokens", type=int, default=1800)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--verbose", action="store_true", default=False)
    args = parser.parse_args()

    random.seed(args.seed)
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Load API key from env (fine_tuning/.env should be loaded by caller or environment).
    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("Set OPENAI_API_KEY in environment to run this generator.")

    # Ensure tools schema exists (we only emit write_file anyway, but validate it).
    _ = _load_tools_schema()

    try:
        from openai import OpenAI
    except ImportError:
        raise SystemExit("Missing dependency: install openai (pip install openai).")

    client = OpenAI(api_key=api_key)

    # We only use write_file, but we still train on the *tool choice* and path invariance.
    out_path = Path(args.output)
    if out_path.exists():
        out_path.unlink()

    extends_options = ["Node", "Node2D", "Control", "CharacterBody2D"]
    # We will ask for code containing a marker comment on the function signature line.
    system_prompt = (
        "You are generating training fixtures for a Godot editor assistant.\n"
        "Return ONLY valid JSON.\n"
        "Return an array of objects. Each object MUST have:\n"
        "  - extends_class: string\n"
        "  - fixed_code: string (full GDScript file content)\n"
        "\n"
        "Rules for fixed_code:\n"
        "- The first line MUST be `extends <extends_class>`.\n"
        "- Include exactly ONE function with signature: `func lint_target(x: int) -> void:`\n"
        "  and that SAME line MUST end with the marker comment: `# __LINT_TARGET__`\n"
        "  Example line: `func lint_target(x: int) -> void: # __LINT_TARGET__`\n"
        "- The code must be syntactically valid and lint-clean if possible.\n"
        "- No markdown fences.\n"
        "- Do not include any other files or explanations.\n"
    )

    user_prompt_template = (
        "Generate {n} fixed_code candidates.\n"
        "Choose extends_class randomly from: {extends_list}.\n"
    )

    target = args.count
    written = 0
    attempts = 0
    openai_batches = 0

    fail_reasons: Dict[str, int] = {
        "openai_invalid_json": 0,
        "candidate_not_dict": 0,
        "fixed_code_empty": 0,
        "corrupt_none": 0,
        "broken_lint_returned_ok": 0,
        "broken_no_lint_output": 0,
        "fixed_lint_failed": 0,
        "write_or_lint_exception": 0,
    }

    out_f = out_path.open("w", encoding="utf-8")
    try:
        while written < target and openai_batches < args.batches:
            openai_batches += 1
            attempts += 1

            user_prompt = user_prompt_template.format(
                n=args.candidates_per_batch,
                extends_list=", ".join(extends_options),
            )

            resp = client.chat.completions.create(
                model=args.model,
                temperature=args.temperature,
                max_tokens=args.max_tokens,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
            )

            raw_text = (resp.choices[0].message.content or "").strip()
            try:
                items = _safe_json_loads(raw_text)
            except JSONParseError:
                fail_reasons["openai_invalid_json"] += 1
                continue
            if not isinstance(items, list):
                continue

            for cand_idx, item in enumerate(items):
                if written >= target:
                    break
                if not isinstance(item, dict):
                    fail_reasons["candidate_not_dict"] += 1
                    continue

                fixed_code = str(item.get("fixed_code") or "")
                if not fixed_code.strip():
                    fail_reasons["fixed_code_empty"] += 1
                    continue

                broken_code = _corrupt_code_to_create_parse_error(fixed_code)
                if not broken_code:
                    fail_reasons["corrupt_none"] += 1
                    continue

                tmp_name = f"lint_repair_tmp_{out_path.stem}_{written}_{cand_idx}.gd"
                plugin_script_path = f"res://scripts/{tmp_name}"
                plugin_abs_path = GODOT_PLUGIN_SCRIPTS_DIR / tmp_name
                try:
                    # Write broken code to disk
                    plugin_abs_path.parent.mkdir(parents=True, exist_ok=True)
                    plugin_abs_path.write_text(broken_code, encoding="utf-8")
                    broken_lint = run_gdlint_on_plugin_script(plugin_script_path)
                    if broken_lint.ok:
                        fail_reasons["broken_lint_returned_ok"] += 1
                        continue
                    if not broken_lint.lint_output:
                        fail_reasons["broken_no_lint_output"] += 1
                        continue

                    # Overwrite with fixed code and ensure it passes
                    plugin_abs_path.write_text(fixed_code, encoding="utf-8")
                    fixed_lint = run_gdlint_on_plugin_script(plugin_script_path)
                    if not fixed_lint.ok:
                        fail_reasons["fixed_lint_failed"] += 1
                        if args.verbose and fail_reasons["fixed_lint_failed"] <= 3:
                            print("\n--- DEBUG fixed_lint_failed ---")
                            print(f"tmp={tmp_name}")
                            print("gdlint raw lint_output:\n", fixed_lint.lint_output)
                            print("fixed_code (head):\n", "\n".join(fixed_code.splitlines()[:30]))
                            print("--- END DEBUG ---\n")
                        continue

                    user_content = _build_user_content(
                        broken_code=broken_code,
                        lint_output=broken_lint.lint_output,
                        active_script_path=plugin_script_path,
                    )
                    assistant_content = _build_assistant_tool_call_write_file(
                        path=plugin_script_path,
                        content=fixed_code,
                    )

                    record = {
                        "messages": [
                            {"role": "system", "content": COMPOSER_V2_SYSTEM_PROMPT_AGENT},
                            {"role": "user", "content": user_content},
                            {"role": "assistant", "content": assistant_content},
                        ]
                    }

                    out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
                    out_f.flush()
                    written += 1

                    # Cleanup temp file (avoid leaving artifacts).
                    try:
                        plugin_abs_path.unlink()
                    except Exception:
                        pass
                except Exception:
                    fail_reasons["write_or_lint_exception"] += 1
                    try:
                        plugin_abs_path.unlink()
                    except Exception:
                        pass
                    continue

    finally:
        out_f.close()

    print(f"Generated {written} lint-repair examples -> {out_path}")
    if args.verbose:
        print("Skip reason counters:")
        for k, v in sorted(fail_reasons.items(), key=lambda kv: -kv[1]):
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()

