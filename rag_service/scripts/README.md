# RAG service scripts

All scripts live in this folder (no subfolders). Run from `rag_service` unless noted.

## Repo index (SQLite)

- **index_repo.py** – CLI to build/update the SQLite repo index for a Godot project. The implementation is in `app.services.repo_indexing`; this script just calls it.
  ```bash
  python scripts/index_repo.py --project-root /path/to/project
  ```

## Chroma / project code index

- **analyze_project.py** – Analyzes Godot projects (or scraped component folders), computes importance/tags, and optionally writes to Chroma `project_code`. Tag rules (extends/path_keywords) are defined in the script.
  ```bash
  python scripts/analyze_project.py --source-root /path/to/project   # single project
  python scripts/analyze_project.py --scraped-root /path/to/scraped_repos   # default layout
  ```
- **script_extends.py** – Shared helper for inferring extends/class from script content. Used by `analyze_project` and `fetch_top_godot_repos`.

## Scraping (optional, for building knowledge base)

- **fetch_top_godot_repos.py** – Fetches top Godot repos from GitHub, copies Godot-relevant files into a by-component layout, prunes non-native folders into `Other/` (use `--no-prune` to skip), then runs `analyze_project` unless `--no-analyze`.

## Inspection

- **chroma-status.ps1** – Prints ChromaDB collection counts and sample docs.
- **chroma_visualize.py** – Small FastAPI app to browse Chroma collections in the browser.

## Other

- **gdlint.ps1** – Godot script lint helper (if used by your workflow).

---

For **evaluation** (Godot Composer vs GPT-4.1-mini), use the **testing** package under `rag_service/testing/` (see `testing/README.md`).
