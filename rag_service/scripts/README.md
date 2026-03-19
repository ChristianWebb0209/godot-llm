# RAG service scripts

All scripts live in this folder (no subfolders). Run from `rag_service` unless noted.

## Repo index (SQLite)

- **index_repo.py** – CLI to build/update the SQLite repo index for a Godot project. The implementation is in `app.services.repo_indexing`; this script just calls it.
  ```bash
  python scripts/index_repo.py --project-root /path/to/project
  ```

## Project code index (deprecated)

Project code indexing into ChromaDB / Supabase pgvector has been removed from this repo.

The remaining helper:
- **script_extends.py** – Shared helper for inferring extends/class from script content. Used by `fetch_top_godot_repos`.

## Scraping (optional, for building knowledge base)

- **fetch_top_godot_repos.py** – Fetches top Godot repos from GitHub, copies Godot-relevant files into a by-component layout, and prunes non-native folders into `Other/` (use `--no-prune` to skip).

## Inspection

ChromaDB inspection helpers were removed together with vector indexing.

## Other

- **gdlint.ps1** – Godot script lint helper (if used by your workflow).

---

For **evaluation** (Godot Composer vs GPT-4.1-mini), use the **testing** package under `fine_tuning/testing/` (see `fine_tuning/testing/README.md`).
