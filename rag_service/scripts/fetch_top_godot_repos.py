#!/usr/bin/env python3
"""
Fetch the top N open-source Godot projects from GitHub and extract only
Godot-relevant files.

- Finds repos by topic (godot), sorted by stars; excludes names containing "engine" or "godot".
- Only keeps repos that have project.godot at root (actual Godot projects).
- Only keeps Godot 4.0+ projects (config_version=5 for 4.2+, or config_version=4 with [rendering] for 4.0/4.1).
- Shallow-clones each repo (no timeout); then copies only: .gd, .cs, .gdshader, .tscn, project.godot (optional).
- Output: output/<ExtendsClass>/repo__path__to__file.gd (one folder per component only; no per-repo folders).
- Running the script empties the output directory first (no prompt).
- After scraping, runs analyze_project.py on the scraped repos (unless --no-analyze).

Usage:
  python fetch_top_godot_repos.py [--output-dir DIR] [--top N] [--include-project] [--no-analyze]
  Set GITHUB_TOKEN in env for higher rate limits (optional).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Allow importing script_extends from same directory (scripts/).
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))
from script_extends import GODOT_NATIVE_EXTENDS, get_extends_from_content

try:
    import requests
except ImportError:
    requests = None

# File extensions to keep (case-insensitive).
KEEP_EXTENSIONS = {".gd", ".cs", ".gdshader", ".tscn"}
# Optional: also keep files named exactly project.godot.
INCLUDE_PROJECT_FILENAME = "project.godot"

# Script lives in rag_service/scripts/ -> RAG_SERVICE_ROOT = rag_service
SCRIPT_DIR = Path(__file__).resolve().parent
RAG_SERVICE_ROOT = SCRIPT_DIR.parent
DEFAULT_OUTPUT = RAG_SERVICE_ROOT.parent / "godot_knowledge_base" / "scraped_repos"


def _prune_non_native_folders(scraped_dir: Path, dry_run: bool) -> tuple[list[str], int]:
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
        if name in ("Other", "ProjectConfig", "_repos"):
            continue
        if name in GODOT_NATIVE_EXTENDS:
            continue
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
            dest_name = f"{name}__{f.name}"
            dest = other_dir / dest_name
            if dry_run:
                total_moved += 1
                continue
            base, suffix = dest.stem, dest.suffix
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


def _sanitize_repo_folder_name(owner: str, repo: str) -> str:
    """One folder per repo: owner_repo with safe filesystem characters."""
    safe_owner = re.sub(r"[\\/:*?\"<>|\s]+", "_", owner).strip("_") or "owner"
    safe_repo = re.sub(r"[\\/:*?\"<>|\s]+", "_", repo).strip("_") or "repo"
    return f"{safe_owner}_{safe_repo}"


def _sanitize_component_name(component: str) -> str:
    """Safe folder name for extends class (e.g. CharacterBody2D -> CharacterBody2D)."""
    return re.sub(r"[\\/:*?\"<>|\s]+", "_", component).strip("_") or "Node"


def _by_component_filename(repo_folder: str, rel_path: Path) -> str:
    """Single filename for by_component: repo__path__to__file.gd."""
    parts = rel_path.as_posix().replace("\\", "/").split("/")
    safe = "__".join(re.sub(r'[\\/:*?"<>|\s]+', "_", p) for p in parts)
    return f"{repo_folder}__{safe}"


def _is_godot_4_or_above(project_godot_path: Path) -> bool:
    """
    Return True if project.godot is for Godot 4.0 or above.
    - config_version=5 -> Godot 4.2+
    - config_version=4 with [rendering] section -> Godot 4.0/4.1 (Godot 3.x has no [rendering])
    """
    try:
        text = project_godot_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    config_version: int | None = None
    has_rendering = "[rendering]" in text or "rendering/" in text
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("config_version="):
            try:
                config_version = int(line.split("=", 1)[1].strip())
            except (ValueError, IndexError):
                pass
            break
    if config_version is None:
        return False
    if config_version >= 5:
        return True
    if config_version == 4 and has_rendering:
        return True
    return False


def get_top_godot_repos(top: int = 30, token: str | None = None) -> list[dict]:
    """Return list of {full_name, clone_url, default_branch, stars} for top Godot repos."""
    if requests is None:
        raise RuntimeError("Install requests: pip install requests")

    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    # Search: topic godot, sort by stars. Paginate until we have enough after exclusions.
    url = "https://api.github.com/search/repositories"
    skip_words = ("engine", "godot")
    need = max(1, top)
    collected: list[dict] = []
    page = 1
    per_page = 100
    while len(collected) < need:
        params = {
            "q": "topic:godot",
            "sort": "stars",
            "order": "desc",
            "per_page": per_page,
            "page": page,
        }
        r = requests.get(url, headers=headers, params=params, timeout=30)
        r.raise_for_status()
        data = r.json()
        items = data.get("items", [])
        if not items:
            break
        for repo in items:
            if any(w in repo["full_name"].lower() for w in skip_words):
                continue
            collected.append({
                "full_name": repo["full_name"],
                "clone_url": repo["clone_url"],
                "default_branch": repo.get("default_branch", "main"),
                "stars": repo.get("stargazers_count", 0),
            })
            if len(collected) >= need:
                break
        if len(items) < per_page:
            break
        page += 1
        if page > 10:
            break
    return collected[:need]


REPOS_SUBDIR = "_repos"  # Per-repo layout for analyze_project (only when not --no-analyze).


def clone_and_extract(
    clone_url: str,
    branch: str,
    output_dir: Path,
    include_project: bool,
    owner: str,
    repo: str,
    write_per_repo: bool = False,
) -> int:
    """
    Shallow-clone the repo (no timeout). Skip if project.godot is not at root or not Godot 4.0+.
    Copy into output_dir/<ExtendsClass>/repo__path__file.ext (component-only).
    If write_per_repo=True, also copy into output_dir/_repos/repo_folder/rel so analyze_project can run.
    Returns number of files copied.
    """
    with tempfile.TemporaryDirectory(prefix="godot_fetch_") as tmp:
        tmp_path = Path(tmp)
        try:
            subprocess.run(
                [
                    "git",
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    branch,
                    clone_url,
                    str(tmp_path),
                ],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            print(f"  [skip] clone failed: {e.stderr.decode() if e.stderr else e}", file=sys.stderr)
            return 0
        except FileNotFoundError:
            print("  [skip] git not found", file=sys.stderr)
            return 0

        # Only accept repos that have project.godot at root (actual Godot projects).
        project_godot = tmp_path / "project.godot"
        if not project_godot.exists():
            print("  [skip] no project.godot at root (not a Godot project)", file=sys.stderr)
            return 0
        if not _is_godot_4_or_above(project_godot):
            print("  [skip] not Godot 4.0+ (config_version or [rendering] check)", file=sys.stderr)
            return 0

        repo_folder = _sanitize_repo_folder_name(owner, repo)
        # When write_per_repo, we need project.godot in _repos for analyze_project.
        include_project_for_repos = include_project or write_per_repo
        count = 0
        for f in tmp_path.rglob("*"):
            if not f.is_file():
                continue
            rel = f.relative_to(tmp_path)
            keep = False
            if rel.name == INCLUDE_PROJECT_FILENAME and include_project_for_repos:
                keep = True
            elif f.suffix and f.suffix.lower() in KEEP_EXTENSIONS:
                keep = True
            if not keep:
                continue
            # Component-only layout: output_dir/<ExtendsClass>/repo__path__to__file.ext
            if f.suffix and f.suffix.lower() in KEEP_EXTENSIONS:
                try:
                    content = f.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    content = ""
                component = get_extends_from_content(content, f)
                component_safe = _sanitize_component_name(component)
                comp_dir = output_dir / component_safe
                comp_dir.mkdir(parents=True, exist_ok=True)
                dest_name = _by_component_filename(repo_folder, rel)
                shutil.copy2(f, comp_dir / dest_name)
                count += 1
            elif rel.name == INCLUDE_PROJECT_FILENAME and include_project:
                # project.godot: put in ProjectConfig so it's not lost
                comp_dir = output_dir / "ProjectConfig"
                comp_dir.mkdir(parents=True, exist_ok=True)
                dest_name = _by_component_filename(repo_folder, rel)
                shutil.copy2(f, comp_dir / dest_name)
                count += 1
            # Per-repo layout for analyze_project: output_dir/_repos/repo_folder/path/to/file
            if write_per_repo and (rel.name != INCLUDE_PROJECT_FILENAME or include_project_for_repos):
                repos_root = output_dir / REPOS_SUBDIR / repo_folder
                dest = repos_root / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, dest)
                if rel.name == INCLUDE_PROJECT_FILENAME and not include_project:
                    count += 1  # project.godot only copied to _repos, not ProjectConfig
        return count


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fetch top Godot repos from GitHub (only repos with project.godot at root). Output: one folder per component under output dir (e.g. scraped_repos/CharacterBody2D/). No per-repo folders. Empties output dir first."
    )
    ap.add_argument(
        "--output-dir",
        "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output directory (default: {DEFAULT_OUTPUT})",
    )
    ap.add_argument(
        "--top",
        "-n",
        type=int,
        default=30,
        help="Number of top repos to fetch (default: 30)",
    )
    ap.add_argument(
        "--include-project",
        action="store_true",
        help="Also copy project.godot files",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Only list repos, do not clone",
    )
    ap.add_argument(
        "--no-analyze",
        action="store_true",
        help="Do not run analyze_project.py after scraping",
    )
    ap.add_argument(
        "--analyze-importance-threshold",
        type=float,
        default=0.3,
        help="Importance threshold for analyze_project (default: 0.3)",
    )
    ap.add_argument(
        "--analyze-clean",
        action="store_true",
        help="Clean code/demos and index before analyzing (removes existing demo output)",
    )
    ap.add_argument(
        "--no-prune",
        action="store_true",
        help="Do not move non-native component folders into Other/ after scraping",
    )
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "").strip() or None
    if not token:
        print("Tip: set GITHUB_TOKEN for higher API rate limits.", file=sys.stderr)

    print("Fetching top Godot repos from GitHub...")
    try:
        repos = get_top_godot_repos(top=args.top, token=token)
    except Exception as e:
        print(f"GitHub API error: {e}", file=sys.stderr)
        return 1

    if not repos:
        print("No repos found.", file=sys.stderr)
        return 1

    print(f"Found {len(repos)} repos (top by stars).")
    for i, r in enumerate(repos, 1):
        print(f"  {i}. {r['full_name']} (stars={r['stars']})")

    if args.dry_run:
        print("Dry run: not cloning.")
        return 0

    write_per_repo = not args.no_analyze  # So analyze_project can run on output_dir/_repos

    # Empty output directory first (no prompt).
    if args.output_dir.exists():
        shutil.rmtree(args.output_dir)
    args.output_dir.mkdir(parents=True)

    total_files = 0
    for r in repos:
        full_name = r["full_name"]
        owner, repo = full_name.split("/", 1)
        print(f"Cloning {full_name}...", end=" ", flush=True)
        n = clone_and_extract(
            r["clone_url"],
            r["default_branch"],
            args.output_dir,
            args.include_project,
            owner,
            repo,
            write_per_repo=write_per_repo,
        )
        total_files += n
        print(f"{n} files.")

    print(f"Done. {total_files} files in {args.output_dir}")

    # Prune: move non-native component folders (e.g. custom classes) into Other/.
    if not args.dry_run and not args.no_prune and total_files > 0:
        pruned, moved = _prune_non_native_folders(args.output_dir, dry_run=False)
        if pruned:
            print(f"Pruned {len(pruned)} non-native folder(s) into Other/: {moved} files moved.")

    # Run analyze_project on component folders (one index per component).
    if not args.dry_run and not args.no_analyze and total_files > 0:
        analyze_script = SCRIPT_DIR / "analyze_project.py"
        if not analyze_script.exists():
            print("Warning: analyze_project.py not found, skipping analysis.", file=sys.stderr)
        else:
            cmd = [
                sys.executable,
                str(analyze_script),
                "--scraped-root",
                str(args.output_dir.resolve()),
            ]
            if args.analyze_clean:
                cmd.append("--clean")
            print("Running analyze_project on scraped component folders...")
            try:
                subprocess.run(cmd, check=True, cwd=str(analyze_script.parent))
            except subprocess.CalledProcessError as e:
                print(f"analyze_project failed (exit code {e.returncode})", file=sys.stderr)
                return e.returncode

    return 0


if __name__ == "__main__":
    sys.exit(main())
