import os
from pathlib import Path
from typing import Dict, List

import chromadb
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse
import uvicorn


def get_db_root() -> Path:
    """
    Resolve the ChromaDB root used by the rest of the project.
    Defaults to rag_service/data/chroma_db relative to this file.
    """
    base = Path(__file__).resolve()
    return (base.parent / ".." / ".." / "data" / "chroma_db").resolve()


def get_client() -> chromadb.PersistentClient:
    db_root = get_db_root()
    db_root.mkdir(parents=True, exist_ok=True)
    return chromadb.PersistentClient(path=str(db_root))


app = FastAPI(
    title="Chroma Visualizer",
    description="Simple ChromaDB browser for Godot LLM Assistant.",
)


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    client = get_client()
    collections = client.list_collections()

    rows: List[str] = []
    for coll in collections:
        try:
            count = coll.count()
        except Exception as e:
            count = f"error: {e}"
        rows.append(
            f"<tr>"
            f"<td><a href='/collections/{coll.name}'>{coll.name}</a></td>"
            f"<td>{count}</td>"
            f"</tr>"
        )

    if not rows:
        rows_html = "<tr><td colspan='2'><em>No collections found.</em></td></tr>"
    else:
        rows_html = "\n".join(rows)

    db_root = get_db_root()

    html = f"""
    <html>
      <head>
        <title>Chroma Visualizer</title>
        <style>
          body {{ font-family: system-ui, sans-serif; margin: 2rem; background: #101318; color: #e4e7ec; }}
          a {{ color: #7dd3fc; text-decoration: none; }}
          a:hover {{ text-decoration: underline; }}
          table {{ border-collapse: collapse; width: 100%; margin-top: 1rem; }}
          th, td {{ border-bottom: 1px solid #1f2937; padding: 0.5rem 0.75rem; text-align: left; }}
          th {{ background: #111827; }}
          tr:nth-child(even) td {{ background: #020617; }}
          .muted {{ color: #9ca3af; }}
          .header {{ font-size: 1.5rem; margin-bottom: 0.25rem; }}
          .subheader {{ color: #9ca3af; margin-bottom: 1.5rem; }}
        </style>
      </head>
      <body>
        <div class="header">ChromaDB Collections</div>
        <div class="subheader">DB root: {db_root}</div>
        <table>
          <thead>
            <tr>
              <th>Collection</th>
              <th>Count</th>
            </tr>
          </thead>
          <tbody>
            {rows_html}
          </tbody>
        </table>
      </body>
    </html>
    """
    return html


@app.get("/collections/{name}", response_class=HTMLResponse)
def view_collection(
    name: str,
    limit: int = Query(50, ge=1, le=500),
) -> str:
    """
    Show a sample of documents from a collection.
    Uses peek() to fetch up to `limit` entries.
    """
    client = get_client()
    try:
        coll = client.get_collection(name)
    except Exception:
        raise HTTPException(status_code=404, detail=f"Collection '{name}' not found")

    try:
        total = coll.count()
    except Exception:
        total = "unknown"

    try:
        peek = coll.peek(limit)
    except TypeError:
        # Older chroma versions ignore arguments; just call without.
        peek = coll.peek()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to peek collection: {e}")

    ids = (peek.get("ids") or [[]])[0]
    docs = (peek.get("documents") or [[]])[0]
    metas = (peek.get("metadatas") or [[]])[0]

    rows: List[str] = []
    for i, doc_id in enumerate(ids):
        meta: Dict[str, object] = metas[i] if i < len(metas) and metas[i] else {}
        path = meta.get("path", "")
        language = meta.get("language", "")
        importance = meta.get("importance", None)
        tags = meta.get("tags", None)

        preview = ""
        if i < len(docs) and docs[i]:
            preview_lines = str(docs[i]).splitlines()
            preview = "\n".join(preview_lines[:8])
            if len(preview_lines) > 8:
                preview += "\n..."

        meta_lines: List[str] = []
        if path:
            meta_lines.append(f"<div><span class='muted'>path:</span> {path}</div>")
        if language:
            meta_lines.append(f"<div><span class='muted'>language:</span> {language}</div>")
        if importance is not None:
            meta_lines.append(f"<div><span class='muted'>importance:</span> {importance}</div>")
        if tags:
            meta_lines.append(f"<div><span class='muted'>tags:</span> {tags}</div>")

        meta_html = "\n".join(meta_lines) or "<div class='muted'>(no metadata)</div>"
        preview_html = (
            "<pre style='white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "
            "\"Liberation Mono\", \"Courier New\", monospace;'>"
            f"{preview}"
            "</pre>"
            if preview
            else "<div class='muted'>(no document text)</div>"
        )

        rows.append(
            f"<tr>"
            f"<td><code>{doc_id}</code></td>"
            f"<td>{meta_html}</td>"
            f"<td>{preview_html}</td>"
            f"</tr>"
        )

    if not rows:
        rows_html = "<tr><td colspan='3'><em>No documents in this collection.</em></td></tr>"
    else:
        rows_html = "\n".join(rows)

    html = f"""
    <html>
      <head>
        <title>Chroma Visualizer – {name}</title>
        <style>
          body {{ font-family: system-ui, sans-serif; margin: 2rem; background: #101318; color: #e4e7ec; }}
          a {{ color: #7dd3fc; text-decoration: none; }}
          a:hover {{ text-decoration: underline; }}
          table {{ border-collapse: collapse; width: 100%; margin-top: 1rem; }}
          th, td {{ border-bottom: 1px solid #1f2937; padding: 0.5rem 0.75rem; text-align: left; vertical-align: top; }}
          th {{ background: #111827; }}
          tr:nth-child(even) td {{ background: #020617; }}
          .muted {{ color: #9ca3af; }}
          .header {{ font-size: 1.5rem; margin-bottom: 0.25rem; }}
          .subheader {{ color: #9ca3af; margin-bottom: 1.5rem; }}
        </style>
      </head>
      <body>
        <div class="header">Collection: {name}</div>
        <div class="subheader">
          <a href="/">← Back to collections</a> ·
          Total docs: {total} ·
          Showing up to {limit} entries from peek()
        </div>
        <table>
          <thead>
            <tr>
              <th style="width: 15%;">ID</th>
              <th style="width: 30%;">Metadata</th>
              <th>Preview</th>
            </tr>
          </thead>
          <tbody>
            {rows_html}
          </tbody>
        </table>
      </body>
    </html>
    """
    return html


def main() -> None:
    """
    Run the Chroma visualizer on http://127.0.0.1:8001 by default.
    """
    host = os.getenv("CHROMA_VIS_HOST", "127.0.0.1")
    port = int(os.getenv("CHROMA_VIS_PORT", "8001"))
    uvicorn.run("chroma_visualize:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()