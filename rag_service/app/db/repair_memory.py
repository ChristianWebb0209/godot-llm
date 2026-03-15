import difflib
import hashlib
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


def _db_path() -> str:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    return os.path.join(root, "data", "db", "repair_memory.db")


def get_conn() -> sqlite3.Connection:
    path = _db_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    conn.execute("PRAGMA busy_timeout=3000;")
    return conn


def init_repair_memory_db() -> None:
    conn = get_conn()
    try:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS lint_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              project_root_abs TEXT NOT NULL,
              file_path TEXT NOT NULL,
              engine_version TEXT NOT NULL,
              started_ts REAL NOT NULL,
              finished_ts REAL,
              status TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS lint_errors (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL REFERENCES lint_sessions(id) ON DELETE CASCADE,
              error_hash TEXT NOT NULL,
              error_type TEXT NOT NULL,
              error_message TEXT NOT NULL,
              raw_output TEXT NOT NULL,
              occurred_ts REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS lint_fixes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL REFERENCES lint_sessions(id) ON DELETE CASCADE,
              error_hash TEXT NOT NULL,
              old_content TEXT NOT NULL,
              new_content TEXT NOT NULL,
              diff TEXT NOT NULL,
              explanation TEXT NOT NULL,
              model TEXT,
              created_ts REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_lint_errors_hash ON lint_errors(error_hash, occurred_ts DESC);
            CREATE INDEX IF NOT EXISTS idx_lint_fixes_hash ON lint_fixes(error_hash, created_ts DESC);
            CREATE INDEX IF NOT EXISTS idx_lint_fixes_file ON lint_sessions(file_path, finished_ts DESC);
            """
        )
        conn.commit()
    finally:
        conn.close()


_RE_ABS_PATH = re.compile(r"[A-Za-z]:\\\\[^\\s:]+")
_RE_RES_PATH = re.compile(r"res://[^\\s:]+")
_RE_LINECOL = re.compile(r"(?:line|Line)\\s*\\d+|\\(\\d+,\\d+\\)|:\\d+:\\d+|:\\d+")
_RE_QUOTED = re.compile(r"'[^']+'|\"[^\"]+\"")


def _pick_error_message(raw_output: str) -> str:
    for ln in (raw_output or "").splitlines():
        s = ln.strip()
        if s:
            return s
    return (raw_output or "").strip() or "Lint failed"


def _error_type_from_message(msg: str) -> str:
    m = (msg or "").lower()
    if "parse" in m or "parser" in m or "unexpected" in m:
        return "PARSE_ERROR"
    if "type" in m or "cannot convert" in m:
        return "TYPE_ERROR"
    if "invalid call" in m or "nonexistent function" in m:
        return "INVALID_CALL"
    if "unknown identifier" in m or "not declared" in m:
        return "UNKNOWN_IDENTIFIER"
    return "OTHER"


def normalize_error(raw_output: str) -> Tuple[str, str, str]:
    """
    Returns (error_type, error_message, normalized_signature_text).
    """
    msg = _pick_error_message(raw_output)
    err_type = _error_type_from_message(msg)
    sig = msg
    sig = _RE_ABS_PATH.sub("<ABS_PATH>", sig)
    sig = _RE_RES_PATH.sub("<RES_PATH>", sig)
    sig = _RE_LINECOL.sub("<LOC>", sig)
    sig = _RE_QUOTED.sub("<ID>", sig)
    sig = re.sub(r"\\d+", "<N>", sig)
    sig = re.sub(r"\\s+", " ", sig).strip()
    return err_type, msg, sig


def _sha256_text(s: str) -> str:
    return hashlib.sha256((s or "").encode("utf-8")).hexdigest()


def error_hash(raw_output: str, engine_version: str) -> str:
    _, _, sig = normalize_error(raw_output)
    return _sha256_text(f"{sig}|{engine_version or ''}")[:32]


def unified_diff(old: str, new: str, file_path: str) -> str:
    old_lines = (old or "").splitlines(keepends=True)
    new_lines = (new or "").splitlines(keepends=True)
    diff_lines = list(
        difflib.unified_diff(
            old_lines,
            new_lines,
            fromfile=f"a/{file_path}",
            tofile=f"b/{file_path}",
            lineterm="",
        )
    )
    return "\n".join(diff_lines)


def create_lint_fix_record(
    *,
    project_root_abs: str,
    file_path: str,
    engine_version: str,
    raw_lint_output: str,
    old_content: str,
    new_content: str,
    explanation: str,
    model: Optional[str] = None,
) -> Dict[str, Any]:
    init_repair_memory_db()
    ts = time.time()
    e_type, e_msg, _sig = normalize_error(raw_lint_output)
    e_hash = error_hash(raw_lint_output, engine_version)
    diff = unified_diff(old_content, new_content, file_path=file_path)

    conn = get_conn()
    try:
        cur = conn.execute(
            """
            INSERT INTO lint_sessions(project_root_abs, file_path, engine_version, started_ts, finished_ts, status)
            VALUES (?,?,?,?,?,?)
            """,
            (project_root_abs, file_path, engine_version, ts, ts, "ok"),
        )
        session_id = int(cur.lastrowid)

        conn.execute(
            """
            INSERT INTO lint_errors(session_id, error_hash, error_type, error_message, raw_output, occurred_ts)
            VALUES (?,?,?,?,?,?)
            """,
            (session_id, e_hash, e_type, e_msg, raw_lint_output, ts),
        )

        cur2 = conn.execute(
            """
            INSERT INTO lint_fixes(session_id, error_hash, old_content, new_content, diff, explanation, model, created_ts)
            VALUES (?,?,?,?,?,?,?,?)
            """,
            (session_id, e_hash, old_content, new_content, diff, explanation, model, ts),
        )
        fix_id = int(cur2.lastrowid)
        conn.commit()
        return {
            "ok": True,
            "fix_id": fix_id,
            "session_id": session_id,
            "error_hash": e_hash,
            "error_type": e_type,
            "error_message": e_msg,
        }
    finally:
        conn.close()


def search_lint_fixes(
    *,
    engine_version: str,
    raw_lint_output: str,
    limit: int = 3,
) -> List[Dict[str, Any]]:
    init_repair_memory_db()
    e_hash = error_hash(raw_lint_output, engine_version)
    conn = get_conn()
    try:
        rows = conn.execute(
            """
            SELECT
              lf.id AS id,
              ls.file_path AS file_path,
              ls.engine_version AS engine_version,
              lf.diff AS diff,
              lf.explanation AS explanation,
              lf.model AS model,
              lf.created_ts AS created_ts
            FROM lint_fixes lf
            JOIN lint_sessions ls ON ls.id = lf.session_id
            WHERE lf.error_hash = ?
            ORDER BY lf.created_ts DESC
            LIMIT ?
            """,
            (e_hash, int(limit)),
        ).fetchall()
        return [
            {
                "id": int(r["id"]),
                "file_path": str(r["file_path"]),
                "engine_version": str(r["engine_version"]),
                "diff": str(r["diff"]),
                "explanation": str(r["explanation"]),
                "model": r["model"],
                "created_ts": float(r["created_ts"]),
                "error_hash": e_hash,
            }
            for r in rows
        ]
    finally:
        conn.close()


def format_fixes_for_prompt(results: List[Dict[str, Any]]) -> str:
    if not results:
        return ""
    parts: List[str] = []
    parts.append("Past lint fixes (repair memory):")
    for r in results:
        parts.append(f"- Fix #{r['id']} (file={r['file_path']}, engine={r['engine_version']})")
        exp = (r.get("explanation") or "").strip()
        if exp:
            parts.append(f"  Explanation: {exp}")
        diff = (r.get("diff") or "").strip()
        if diff:
            parts.append("  Diff:")
            parts.append(diff)
    return "\n".join(parts).strip()

