import difflib
import hashlib
import json
import os
import sqlite3
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


def _db_path() -> str:
    # Store alongside other backend data files under rag_service/data/db.
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    return os.path.join(root, "data", "db", "ai_history.db")


def get_conn() -> sqlite3.Connection:
    path = _db_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def init_db() -> None:
    conn = get_conn()
    try:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS edit_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp REAL NOT NULL,
              actor TEXT NOT NULL,
              trigger TEXT NOT NULL,
              prompt_hash TEXT,
              summary TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS file_changes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              edit_id INTEGER NOT NULL REFERENCES edit_events(id) ON DELETE CASCADE,
              file_path TEXT NOT NULL,
              change_type TEXT NOT NULL,
              diff TEXT NOT NULL,
              old_hash TEXT,
              new_hash TEXT,
              lines_added INTEGER NOT NULL DEFAULT 0,
              lines_removed INTEGER NOT NULL DEFAULT 0,
              old_content TEXT,
              new_content TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_edit_events_timestamp ON edit_events(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_file_changes_edit_id ON file_changes(edit_id);

            CREATE TABLE IF NOT EXISTS usage_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                prompt_tokens INTEGER NOT NULL DEFAULT 0,
                completion_tokens INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_usage_log_created_at ON usage_log(created_at DESC);
            """
        )
        conn.commit()
        _migrate_edit_events_columns(conn)
    finally:
        conn.close()


def _migrate_edit_events_columns(conn: sqlite3.Connection) -> None:
    """Add EDIT_HISTORY ai_context columns if missing (prompt, semantic_summary, lint_*)."""
    new_columns = [
        ("prompt", "TEXT"),
        ("semantic_summary", "TEXT"),
        ("lint_errors_before", "TEXT"),
        ("lint_errors_after", "TEXT"),
        ("retrieved_chunk_ids", "TEXT"),  # JSON array of chunk ids
    ]
    for col_name, col_type in new_columns:
        try:
            conn.execute(
                "ALTER TABLE edit_events ADD COLUMN %s %s" % (col_name, col_type)
            )
        except sqlite3.OperationalError as e:
            if "duplicate column name" in str(e).lower():
                pass
            else:
                raise
    conn.commit()


def record_usage(model: str, prompt_tokens: int, completion_tokens: int) -> None:
    """Append one usage record (e.g. after each LLM request that has token counts)."""
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO usage_log (model, prompt_tokens, completion_tokens, created_at) VALUES (?, ?, ?, ?)",
            (model or "unknown", int(prompt_tokens), int(completion_tokens), time.time()),
        )
        conn.commit()
    finally:
        conn.close()


def get_usage_totals() -> Dict[str, Any]:
    """Return aggregated usage: total_prompt_tokens, total_completion_tokens, by_model { model: { prompt_tokens, completion_tokens } }."""
    conn = get_conn()
    try:
        rows = conn.execute(
            """SELECT model, SUM(prompt_tokens) AS prompt_tokens, SUM(completion_tokens) AS completion_tokens
               FROM usage_log GROUP BY model"""
        ).fetchall()
        by_model: Dict[str, Dict[str, int]] = {}
        total_prompt = 0
        total_completion = 0
        for r in rows:
            model = r["model"] or "unknown"
            pt = int(r["prompt_tokens"] or 0)
            ct = int(r["completion_tokens"] or 0)
            by_model[model] = {"prompt_tokens": pt, "completion_tokens": ct}
            total_prompt += pt
            total_completion += ct
        return {
            "total_prompt_tokens": total_prompt,
            "total_completion_tokens": total_completion,
            "by_model": by_model,
        }
    finally:
        conn.close()


def _sha256_text(s: Optional[str]) -> Optional[str]:
    if s is None:
        return None
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _unified_diff(old: str, new: str, file_path: str) -> Tuple[str, int, int]:
    old_lines = old.splitlines(keepends=True)
    new_lines = new.splitlines(keepends=True)
    diff_lines = list(
        difflib.unified_diff(
            old_lines,
            new_lines,
            fromfile=f"a/{file_path}",
            tofile=f"b/{file_path}",
            lineterm="",
        )
    )
    # Count added/removed (ignore headers).
    added = 0
    removed = 0
    for line in diff_lines:
        if line.startswith(("---", "+++", "@@")):
            continue
        if line.startswith("+"):
            added += 1
        elif line.startswith("-"):
            removed += 1
    return "\n".join(diff_lines), added, removed


def create_edit_event(
    *,
    actor: str,
    trigger: str,
    summary: str,
    prompt: Optional[str] = None,
    changes: List[Dict[str, Any]],
    semantic_summary: Optional[str] = None,
    lint_errors_before: Optional[str] = None,
    lint_errors_after: Optional[str] = None,
    retrieved_chunk_ids: Optional[List[str]] = None,
) -> int:
    """
    Create an edit event + its file changes.
    changes items:
      - file_path (project-relative preferred)
      - change_type: create|modify|delete
      - old_content, new_content
    """
    ts = time.time()
    prompt_hash = _sha256_text(prompt) if prompt else None
    chunk_ids_json: Optional[str] = None
    if retrieved_chunk_ids is not None:
        chunk_ids_json = json.dumps(retrieved_chunk_ids)

    conn = get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO edit_events(
                timestamp, actor, trigger, prompt_hash, summary,
                prompt, semantic_summary, lint_errors_before, lint_errors_after, retrieved_chunk_ids
            ) VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (
                ts,
                actor,
                trigger,
                prompt_hash,
                summary,
                prompt,
                semantic_summary,
                lint_errors_before,
                lint_errors_after,
                chunk_ids_json,
            ),
        )
        edit_id = int(cur.lastrowid)

        for ch in changes:
            file_path = str(ch.get("file_path", "") or "")
            change_type = str(ch.get("change_type", "modify") or "modify")
            old_content = ch.get("old_content", "") or ""
            new_content = ch.get("new_content", "") or ""
            diff, added, removed = _unified_diff(old_content, new_content, file_path)
            conn.execute(
                """
                INSERT INTO file_changes(
                  edit_id, file_path, change_type, diff,
                  old_hash, new_hash, lines_added, lines_removed,
                  old_content, new_content
                )
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    edit_id,
                    file_path,
                    change_type,
                    diff,
                    _sha256_text(old_content),
                    _sha256_text(new_content),
                    int(added),
                    int(removed),
                    old_content,
                    new_content,
                ),
            )

        conn.commit()
        return edit_id
    finally:
        conn.close()


def list_edit_events(limit: int = 100) -> List[Dict[str, Any]]:
    conn = get_conn()
    try:
        events = conn.execute(
            """SELECT id, timestamp, actor, trigger, prompt_hash, summary,
                      prompt, semantic_summary, lint_errors_before, lint_errors_after, retrieved_chunk_ids
               FROM edit_events ORDER BY timestamp DESC LIMIT ?""",
            (int(limit),),
        ).fetchall()

        out: List[Dict[str, Any]] = []
        for e in events:
            changes = conn.execute(
                """
                SELECT id, file_path, change_type, diff, lines_added, lines_removed
                FROM file_changes
                WHERE edit_id = ?
                ORDER BY id ASC
                """,
                (int(e["id"]),),
            ).fetchall()
            chunk_ids = None
            try:
                rci = e["retrieved_chunk_ids"]
                if rci:
                    chunk_ids = json.loads(rci)
            except (TypeError, ValueError, KeyError):
                pass
            out.append(
                {
                    "id": int(e["id"]),
                    "timestamp": float(e["timestamp"]),
                    "actor": e["actor"],
                    "trigger": e["trigger"],
                    "prompt_hash": e["prompt_hash"],
                    "summary": e["summary"],
                    "prompt": e["prompt"] if "prompt" in e.keys() else None,
                    "semantic_summary": e["semantic_summary"] if "semantic_summary" in e.keys() else None,
                    "lint_errors_before": e["lint_errors_before"] if "lint_errors_before" in e.keys() else None,
                    "lint_errors_after": e["lint_errors_after"] if "lint_errors_after" in e.keys() else None,
                    "retrieved_chunk_ids": chunk_ids,
                    "changes": [
                        {
                            "id": int(c["id"]),
                            "file_path": c["file_path"],
                            "change_type": c["change_type"],
                            "diff": c["diff"],
                            "lines_added": int(c["lines_added"]),
                            "lines_removed": int(c["lines_removed"]),
                        }
                        for c in changes
                    ],
                }
            )
        return out
    finally:
        conn.close()


def get_edit_event(edit_id: int) -> Optional[Dict[str, Any]]:
    conn = get_conn()
    try:
        e = conn.execute(
            """SELECT id, timestamp, actor, trigger, prompt_hash, summary,
                      prompt, semantic_summary, lint_errors_before, lint_errors_after, retrieved_chunk_ids
               FROM edit_events WHERE id = ?""",
            (int(edit_id),),
        ).fetchone()
        if not e:
            return None
        chunk_ids = None
        try:
            rci = e["retrieved_chunk_ids"]
            if rci:
                chunk_ids = json.loads(rci)
        except (TypeError, ValueError, KeyError):
            pass
        changes = conn.execute(
            """
            SELECT id, file_path, change_type, diff, lines_added, lines_removed, old_content, new_content
            FROM file_changes
            WHERE edit_id = ?
            ORDER BY id ASC
            """,
            (int(edit_id),),
        ).fetchall()
        return {
            "id": int(e["id"]),
            "timestamp": float(e["timestamp"]),
            "actor": e["actor"],
            "trigger": e["trigger"],
            "prompt_hash": e["prompt_hash"],
            "summary": e["summary"],
            "prompt": e["prompt"] if "prompt" in e.keys() else None,
            "semantic_summary": e["semantic_summary"] if "semantic_summary" in e.keys() else None,
            "lint_errors_before": e["lint_errors_before"] if "lint_errors_before" in e.keys() else None,
            "lint_errors_after": e["lint_errors_after"] if "lint_errors_after" in e.keys() else None,
            "retrieved_chunk_ids": chunk_ids,
            "changes": [
                {
                    "id": int(c["id"]),
                    "file_path": c["file_path"],
                    "change_type": c["change_type"],
                    "diff": c["diff"],
                    "lines_added": int(c["lines_added"]),
                    "lines_removed": int(c["lines_removed"]),
                    "old_content": c["old_content"],
                    "new_content": c["new_content"],
                }
                for c in changes
            ],
        }
    finally:
        conn.close()


def list_recent_file_changes(limit_edits: int = 50, max_files: int = 6) -> List[Dict[str, Any]]:
    """
    Recency working set: return the most recently edited distinct files with small metadata + diff.
    """
    conn = get_conn()
    try:
        rows = conn.execute(
            """
            SELECT
              fc.file_path AS file_path,
              fc.change_type AS change_type,
              fc.diff AS diff,
              fc.lines_added AS lines_added,
              fc.lines_removed AS lines_removed,
              ee.id AS edit_id,
              ee.timestamp AS timestamp,
              ee.trigger AS trigger,
              ee.summary AS summary
            FROM file_changes fc
            JOIN edit_events ee ON ee.id = fc.edit_id
            ORDER BY ee.timestamp DESC, fc.id DESC
            LIMIT ?
            """,
            (int(limit_edits),),
        ).fetchall()

        seen: set[str] = set()
        out: List[Dict[str, Any]] = []
        for r in rows:
            fp = str(r["file_path"])
            if fp in seen:
                continue
            seen.add(fp)
            out.append(
                {
                    "file_path": fp,
                    "change_type": str(r["change_type"]),
                    "diff": str(r["diff"]),
                    "lines_added": int(r["lines_added"]),
                    "lines_removed": int(r["lines_removed"]),
                    "edit_id": int(r["edit_id"]),
                    "timestamp": float(r["timestamp"]),
                    "trigger": str(r["trigger"]),
                    "summary": str(r["summary"]),
                }
            )
            if len(out) >= int(max_files):
                break
        return out
    finally:
        conn.close()

