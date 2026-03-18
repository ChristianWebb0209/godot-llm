"""
verify_checkpoints.py
---------------------
Run this BEFORE starting training to verify and fix checkpoint configuration.

Usage:
    python verify_checkpoints.py
    python verify_checkpoints.py --fix          # auto-apply all fixes
    python verify_checkpoints.py --save-steps 75 --fix
    python verify_checkpoints.py --trainer-path path/to/train_lora_gemma_tools.py

What it checks:
    1. That build_trainer reads CHECKPOINT_STEPS from the environment
    2. That save_strategy is set to "steps" (not "epoch" or "no")
    3. That save_total_limit is >= 3
    4. That output_dir / checkpoint dir is pointing at Drive (in Colab)
    5. That the Drive path is actually mounted and writable
"""

import argparse
import ast
import os
import sys
import tempfile
import time
from pathlib import Path


# ── ANSI colours ──────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
YELLOW = "\033[93m"
RED    = "\033[91m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

def ok(msg):    print(f"  {GREEN}✔{RESET}  {msg}")
def warn(msg):  print(f"  {YELLOW}⚠{RESET}  {msg}")
def fail(msg):  print(f"  {RED}✘{RESET}  {msg}")
def info(msg):  print(f"  {CYAN}→{RESET}  {msg}")
def header(msg): print(f"\n{BOLD}{msg}{RESET}\n{'─'*60}")


# ── Helpers ───────────────────────────────────────────────────────────────────

def find_trainer_file(hint: str | None = None) -> Path | None:
    candidates = [
        hint,
        "fine_tuning/colab/train_lora_gemma_tools.py",
        "train_lora_gemma_tools.py",
    ]
    for c in candidates:
        if c and Path(c).exists():
            return Path(c)
    # Walk up a few levels looking for it
    for depth in range(4):
        base = Path(*(["."] + [".."] * depth))
        for p in base.rglob("train_lora_gemma_tools.py"):
            return p
    return None


def parse_training_args(source: str) -> dict:
    """
    Walk the AST of the trainer source file and find keyword arguments
    passed to TrainingArguments(...). Returns a dict of {kwarg_name: node}.
    """
    tree = ast.parse(source)
    results = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func_name = ""
            if isinstance(node.func, ast.Name):
                func_name = node.func.id
            elif isinstance(node.func, ast.Attribute):
                func_name = node.func.attr
            if func_name == "TrainingArguments":
                for kw in node.keywords:
                    results[kw.arg] = kw.value
    return results


def ast_node_to_str(node) -> str:
    """Best-effort human-readable representation of an AST node."""
    try:
        return ast.unparse(node)
    except Exception:
        return repr(node)


def reads_env_var(node, var_name: str) -> bool:
    """Return True if the AST node contains os.environ.get(var_name, ...)."""
    source = ast_node_to_str(node)
    return var_name in source and "environ" in source


# ── Check 1: trainer file exists ──────────────────────────────────────────────

def check_trainer_exists(trainer_path: Path | None):
    header("CHECK 1 — Trainer source file")
    if trainer_path is None:
        fail("Could not find train_lora_gemma_tools.py anywhere under the current directory.")
        info("Pass --trainer-path explicitly if the file is in a non-standard location.")
        return None
    ok(f"Found trainer file: {trainer_path}")
    return trainer_path


# ── Check 2: TrainingArguments kwargs ─────────────────────────────────────────

def check_training_arguments(trainer_path: Path, save_steps_target: int, auto_fix: bool):
    header("CHECK 2 — TrainingArguments inside build_trainer")

    source = trainer_path.read_text(encoding="utf-8")
    kwargs = parse_training_args(source)

    issues = []  # list of (line_to_find, replacement) for --fix

    # ── save_strategy ────────────────────────────────────────────────────────
    if "save_strategy" not in kwargs:
        fail('save_strategy not set → defaults to "epoch", checkpoints only saved at epoch end')
        issues.append(("save_strategy", None, '"steps"'))
    else:
        val = ast_node_to_str(kwargs["save_strategy"])
        if '"steps"' in val or "'steps'" in val:
            ok(f'save_strategy = {val}')
        else:
            fail(f'save_strategy = {val}  (must be "steps" for mid-epoch saves)')
            issues.append(("save_strategy", val, '"steps"'))

    # ── save_steps ───────────────────────────────────────────────────────────
    if "save_steps" not in kwargs:
        fail("save_steps not set → will use HF default (500 steps)")
        issues.append(("save_steps", None, str(save_steps_target)))
    else:
        val = ast_node_to_str(kwargs["save_steps"])
        reads_env = reads_env_var(kwargs["save_steps"], "CHECKPOINT_STEPS")
        if reads_env:
            ok(f"save_steps reads CHECKPOINT_STEPS env var ({val})")
        else:
            warn(f"save_steps = {val}  — hardcoded, ignores CHECKPOINT_STEPS env var")
            issues.append(("save_steps", val, f'int(os.environ.get("CHECKPOINT_STEPS", {save_steps_target}))'))

    # ── save_total_limit ─────────────────────────────────────────────────────
    if "save_total_limit" not in kwargs:
        fail("save_total_limit not set → HF default keeps only 1 checkpoint (older ones deleted!)")
        issues.append(("save_total_limit", None, "3"))
    else:
        val = ast_node_to_str(kwargs["save_total_limit"])
        try:
            num = int(val)
            if num >= 3:
                ok(f"save_total_limit = {num}")
            else:
                warn(f"save_total_limit = {num}  (recommend >= 3 so a corrupt checkpoint doesn't strand you)")
                issues.append(("save_total_limit", val, "3"))
        except ValueError:
            info(f"save_total_limit = {val}  (dynamic — verify it resolves to >= 3)")

    # ── output_dir ───────────────────────────────────────────────────────────
    if "output_dir" not in kwargs:
        fail("output_dir not set — checkpoints go to the HF default './results', NOT Drive")
        issues.append(("output_dir", None, 'os.environ.get("CHECKPOINT_DIR", "./godot-tools-lora")'))
    else:
        val = ast_node_to_str(kwargs["output_dir"])
        reads_env = reads_env_var(kwargs["output_dir"], "CHECKPOINT_DIR")
        if reads_env:
            ok(f"output_dir reads CHECKPOINT_DIR env var ({val})")
        else:
            warn(f"output_dir = {val}  — hardcoded, ignores CHECKPOINT_DIR env var (won't auto-save to Drive)")
            issues.append(("output_dir", val, 'os.environ.get("CHECKPOINT_DIR", "./godot-tools-lora")'))

    return source, issues


# ── Check 3: Drive mount + writability ────────────────────────────────────────

def check_drive(drive_run_dir: str | None):
    header("CHECK 3 — Google Drive mount & write speed")

    in_colab = Path("/content").exists()
    if not in_colab:
        info("Not running in Colab — Drive check skipped.")
        return

    drive_root = Path("/content/drive/MyDrive")
    if not drive_root.exists():
        fail("/content/drive/MyDrive does not exist — Drive is NOT mounted.")
        info("Run:  from google.colab import drive; drive.mount('/content/drive')")
        return
    ok("Drive is mounted at /content/drive/MyDrive")

    target = Path(drive_run_dir) if drive_run_dir else Path("/content/drive/MyDrive/godot-tools-lora")
    target.mkdir(parents=True, exist_ok=True)

    # Write speed test
    test_file = target / "_write_test.tmp"
    payload = b"x" * (1024 * 1024)  # 1 MB
    try:
        t0 = time.perf_counter()
        test_file.write_bytes(payload)
        elapsed = time.perf_counter() - t0
        test_file.unlink(missing_ok=True)
        mb_s = 1.0 / elapsed
        if mb_s < 0.5:
            warn(f"Drive write speed is slow ({mb_s:.1f} MB/s). "
                 "Saving checkpoints may pause training for 1–2 min each time.")
        else:
            ok(f"Drive is writable — write speed ≈ {mb_s:.1f} MB/s")
    except Exception as e:
        fail(f"Could not write to {target}: {e}")


# ── Apply fixes ───────────────────────────────────────────────────────────────

def apply_fixes(trainer_path: Path, source: str, issues: list, dry_run: bool = False):
    header("FIXES")

    if not issues:
        ok("No fixes needed.")
        return

    new_source = source

    for kwarg, old_val, new_val in issues:
        if old_val is not None:
            # Replace existing kwarg value
            old_pattern = f"{kwarg}={old_val}"
            new_pattern = f"{kwarg}={new_val}"
            if old_pattern in new_source:
                new_source = new_source.replace(old_pattern, new_pattern, 1)
                info(f"{'[DRY RUN] ' if dry_run else ''}Replaced  {old_pattern}  →  {new_pattern}")
            else:
                warn(f"Could not find '{old_pattern}' in source — skipping auto-fix for {kwarg}.")
                info(f"Manually set:  {kwarg}={new_val}")
        else:
            # Kwarg is missing — insert after 'TrainingArguments('
            insert_after = "TrainingArguments("
            insert_line  = f"\n        {kwarg}={new_val},"
            if insert_after in new_source:
                new_source = new_source.replace(insert_after, insert_after + insert_line, 1)
                info(f"{'[DRY RUN] ' if dry_run else ''}Inserted  {kwarg}={new_val}  into TrainingArguments")
            else:
                warn(f"Could not locate TrainingArguments( — skipping auto-fix for {kwarg}.")
                info(f"Manually add to TrainingArguments:  {kwarg}={new_val}")

    if dry_run:
        print(f"\n{YELLOW}Dry run — no files written. Pass --fix to apply.{RESET}")
        return

    # Back up original
    backup = trainer_path.with_suffix(".py.bak")
    backup.write_text(source, encoding="utf-8")
    ok(f"Original backed up to: {backup}")

    trainer_path.write_text(new_source, encoding="utf-8")
    ok(f"Patched file written to: {trainer_path}")


# ── Summary ───────────────────────────────────────────────────────────────────

def print_summary(issues):
    header("SUMMARY")
    if not issues:
        ok("Everything looks good — training should checkpoint safely.")
    else:
        n = len(issues)
        warn(f"{n} issue{'s' if n > 1 else ''} found.")
        info("Re-run with --fix to apply automatic patches, or edit the trainer file manually.")
        print()
        print("  Recommended TrainingArguments block:")
        print(f"""
    TrainingArguments(
        output_dir=os.environ.get("CHECKPOINT_DIR", "./godot-tools-lora"),
        save_strategy="steps",
        save_steps=int(os.environ.get("CHECKPOINT_STEPS", 50)),
        save_total_limit=3,
        ...
    )
""")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Verify and optionally fix checkpoint settings before training."
    )
    parser.add_argument(
        "--trainer-path",
        default=None,
        help="Path to train_lora_gemma_tools.py (auto-detected if omitted)",
    )
    parser.add_argument(
        "--save-steps",
        type=int,
        default=50,
        help="Desired save_steps value (default: 50). Use 50–100 for Colab+Drive.",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Apply fixes automatically (backs up original first).",
    )
    parser.add_argument(
        "--drive-dir",
        default=None,
        help="Drive checkpoint directory to test writability (default: from DRIVE_RUN_DIR env or ~/MyDrive/godot-tools-lora)",
    )
    args = parser.parse_args()

    print(f"\n{BOLD}Checkpoint Configuration Verifier{RESET}")
    print(f"save_steps target: {args.save_steps}  |  auto-fix: {args.fix}")

    trainer_path = check_trainer_exists(find_trainer_file(args.trainer_path))

    all_issues = []
    patched_source = None

    if trainer_path:
        patched_source, issues = check_training_arguments(
            trainer_path, args.save_steps, auto_fix=args.fix
        )
        all_issues.extend(issues)

    check_drive(args.drive_dir or os.environ.get("DRIVE_RUN_DIR"))

    if trainer_path and patched_source is not None:
        apply_fixes(trainer_path, patched_source, all_issues, dry_run=not args.fix)

    print_summary(all_issues)
    sys.exit(0 if not all_issues else 1)


if __name__ == "__main__":
    main()