import argparse
import json
from pathlib import Path

import sys

# Allow running as a script on Windows without installing the package:
# add rag_service/ to sys.path so `import app.*` works.
_RAG_SERVICE_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_RAG_SERVICE_ROOT))

from app.services.repo_indexing import RepoIndexConfig, index_repo


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Index a local Godot project into SQLite (repo_index.db)."
    )
    parser.add_argument(
        "--project-root",
        type=str,
        required=True,
        help="Absolute path to a Godot project root (contains project.godot).",
    )
    parser.add_argument(
        "--reason",
        type=str,
        default="manual",
        help="Reason label for the index run (manual|watcher|startup|...).",
    )
    parser.add_argument(
        "--max-bytes",
        type=int,
        default=1024 * 1024,
        help="Max bytes to read per text file (default 1MB).",
    )
    args = parser.parse_args()

    project_root = Path(args.project_root).expanduser().resolve()
    cfg = RepoIndexConfig(max_text_file_bytes=int(args.max_bytes))
    result = index_repo(
        project_root_abs=str(project_root),
        reason=str(args.reason),
        config=cfg,
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

