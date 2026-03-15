#!/usr/bin/env python3
"""
Prune scraped_repos so only Godot-native component folders remain.
Non-native folders (e.g. SS2D_Action, Weapon, GdUnitAssert) are moved into Other/.

Uses the same native-extends set as fetch_top_godot_repos (script_extends.GODOT_NATIVE_EXTENDS).

Usage:
  python prune_scraped_repos.py [--scraped-dir DIR] [--dry-run]
  Default scraped-dir: ../../../godot_knowledge_base/scraped_repos
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

# Same path setup as fetch_top_godot_repos for importing common.script_extends
_SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from common.script_extends import GODOT_NATIVE_EXTENDS, is_native_godot_extends

RAG_SERVICE_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_SCRAPED_DIR = RAG_SERVICE_ROOT.parent / "godot_knowledge_base" / "scraped_repos"


def prune_scraped_repos(scraped_dir: Path, dry_run: bool) -> tuple[list[str], int]:
    """
    Move files from non-native component folders into Other/.
    Returns (list of folder names that were pruned, total files moved).
    """
    scraped_dir = scraped_dir.resolve()
    if not scraped_dir.is_dir():
        return [], 0

    other_dir = scraped_dir / "Other"
    pruned_folders: list[str] = []
    total_moved = 0

    for d in sorted(scraped_dir.iterdir()):
        if not d.is_dir():
            continue
        name = d.name
        # Skip special folders we don't treat as "component" folders
        if name in ("Other", "ProjectConfig"):
            continue
        # Folder name might have different casing; check against allowed set (case-sensitive as in engine)
        if name in GODOT_NATIVE_EXTENDS:
            continue
        # Non-native: move all files to Other/
        files_here = list(d.iterdir())
        file_count = sum(1 for f in files_here if f.is_file())
        if file_count == 0:
            if not dry_run:
                try:
                    d.rmdir()
                except OSError:
                    pass
            pruned_folders.append(name)
            continue
        if not dry_run:
            other_dir.mkdir(parents=True, exist_ok=True)
        for f in files_here:
            if not f.is_file():
                continue
            # Unique name in Other to avoid overwrites: folder__filename
            dest_name = f"{name}__{f.name}"
            dest = other_dir / dest_name
            if dry_run:
                total_moved += 1
                continue
            # If still exists (rare), append a number
            base = dest.stem
            suffix = dest.suffix
            n = 0
            while dest.exists():
                n += 1
                dest = other_dir / f"{base}_{n}{suffix}"
            shutil.move(str(f), str(dest))
            total_moved += 1
        if not dry_run:
            try:
                d.rmdir()
            except OSError:
                pass
        pruned_folders.append(name)

    return pruned_folders, total_moved


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Prune scraped_repos: move non-native component folders into Other/."
    )
    ap.add_argument(
        "--scraped-dir",
        "-d",
        type=Path,
        default=DEFAULT_SCRAPED_DIR,
        help=f"Path to scraped_repos (default: {DEFAULT_SCRAPED_DIR})",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Only report what would be moved; do not change files.",
    )
    args = ap.parse_args()

    pruned, total = prune_scraped_repos(args.scraped_dir, args.dry_run)
    if not pruned:
        print("No non-native folders to prune.")
        return 0
    print(f"Pruned {len(pruned)} non-native folder(s): {', '.join(pruned)}")
    print(f"Total files moved to Other/: {total}")
    if args.dry_run:
        print("(Dry run; no changes made.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
