import math
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple
import os
import re

from .services.repo_indexing import get_related_res_paths, index_repo


# Conservative, local defaults.
# (We can expand this as we add more models/providers.)
MODEL_CONTEXT_LIMITS: Dict[str, int] = {
    # Reasonable budget for gpt-4.1-mini in practice; we keep it conservative
    # so we have room for tool calls and server-side prompt boilerplate.
    "gpt-4.1-mini": 32768,
}


def get_context_limit(model: str) -> int:
    return int(MODEL_CONTEXT_LIMITS.get(model, 32768))


def estimate_tokens(text: str) -> int:
    """
    Cheap, local estimate. Good enough for UI + budgeting.
    (Rule of thumb: ~4 chars/token in English; code varies but close enough.)
    """
    if not text:
        return 0
    return max(1, math.ceil(len(text) / 4.0))


@dataclass(frozen=True)
class ContextUsage:
    model: str
    limit_tokens: int
    estimated_prompt_tokens: int

    @property
    def percent(self) -> float:
        if self.limit_tokens <= 0:
            return 0.0
        return min(1.0, self.estimated_prompt_tokens / float(self.limit_tokens))


def build_context_usage(model: str, parts: List[str]) -> ContextUsage:
    limit_toks = get_context_limit(model)
    est = sum(estimate_tokens(p) for p in parts if p)
    return ContextUsage(model=model, limit_tokens=limit_toks, estimated_prompt_tokens=est)


def trim_text_to_tokens(text: str, max_tokens: int) -> str:
    """
    Simple truncation stub (Stage 1). Later we can summarize/compress.
    """
    if max_tokens <= 0:
        return ""
    # Approx chars budget.
    max_chars = max_tokens * 4
    if len(text) <= max_chars:
        return text
    return text[: max(0, max_chars - 200)] + "\n\n[...truncated for context budget...]\n"


def _extract_symbol_summary(text: str, max_items: int = 60) -> str:
    """
    Cheap "compression": extract useful symbol lines for Godot-y code.
    """
    lines = text.splitlines()
    keep: List[str] = []
    patterns = (
        "extends ",
        "class_name ",
        "signal ",
        "enum ",
        "@export",
        "const ",
        "var ",
        "func ",
        "static func ",
        "class ",
        "using ",
        "namespace ",
        "public ",
        "private ",
        "#include",
    )
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if s.startswith(patterns):
            keep.append(ln)
            if len(keep) >= max_items:
                break
    return "\n".join(keep)


def compress_text(text: str, max_tokens: int) -> str:
    """
    True compression fallback (no LLM): keep headers + symbols + small windows.
    Used when truncation would discard too much.
    """
    if max_tokens <= 0:
        return ""
    # Small window sizes.
    head_lines = 60
    tail_lines = 40
    lines = text.splitlines()
    head = "\n".join(lines[:head_lines])
    tail = "\n".join(lines[-tail_lines:]) if len(lines) > head_lines else ""
    symbols = _extract_symbol_summary(text, max_items=80)

    out = "\n".join(
        [
            "[compressed summary]",
            "== Key symbols ==",
            symbols or "(none detected)",
            "",
            "== File start ==",
            head,
            "",
            "== File end ==",
            tail,
        ]
    ).strip()
    # Ensure it fits.
    return trim_text_to_tokens(out, max_tokens)


def fit_block_text(text: str, max_tokens: int) -> Tuple[str, str]:
    """
    Decide between truncation vs compression.
    Returns (fitted_text, mode) where mode is 'as_is'|'truncated'|'compressed'.
    """
    if estimate_tokens(text) <= max_tokens:
        return text, "as_is"
    # If we'd lose a lot, compress instead of hard truncating.
    # (Heuristic: > ~35% over budget)
    if estimate_tokens(text) > int(max_tokens * 1.35):
        return compress_text(text, max_tokens), "compressed"
    return trim_text_to_tokens(text, max_tokens), "truncated"


@dataclass(frozen=True)
class ContextBlock:
    key: str
    title: str
    priority: int  # lower = earlier / more important
    max_tokens: int
    text: str


def _dedupe_by_signature(items: List[Tuple[str, str]]) -> List[Tuple[str, str]]:
    """
    Diversity filter: keep first occurrence of identical text bodies.
    items are (signature, text).
    """
    seen: set[str] = set()
    out: List[Tuple[str, str]] = []
    for sig, txt in items:
        if sig in seen:
            continue
        seen.add(sig)
        out.append((sig, txt))
    return out


def build_ordered_blocks(
    *,
    model: str,
    system_instructions: str,
    question: str,
    active_file_path: Optional[str],
    active_file_text: Optional[str],
    errors_text: Optional[str],
    retrieved_docs: List[str],
    retrieved_code: List[str],
    related_files: List[Tuple[str, str]],
    recent_edits: List[str],
    optional_extras: List[str],
    include_system_in_user: bool = False,
) -> List[ContextBlock]:
    """
    Stage-2 context builder with explicit ordering + per-block budgets.
    Order: current task → active file → related → recent edits → errors → retrieved knowledge → optional extras.
    When include_system_in_user is False (default), system instructions are NOT added as a block
    (caller sends them as a separate system message to avoid duplication).
    """
    limit = get_context_limit(model)

    # Budget slices; sum of max_tokens stays <= limit - reserve (see blocks_to_user_content).
    task_budget = min(1200, max(300, int(limit * 0.03)))
    file_budget = min(4500, max(1200, int(limit * 0.15)))
    related_budget = min(3200, max(800, int(limit * 0.10)))
    recent_budget = min(2000, max(400, int(limit * 0.06)))
    err_budget = min(3200, max(600, int(limit * 0.10)))
    know_budget = min(6000, max(1200, int(limit * 0.18)))
    extra_budget = min(2400, max(400, int(limit * 0.08)))

    blocks: List[ContextBlock] = []
    if include_system_in_user:
        sys_budget = min(1200, max(400, int(limit * 0.04)))
        blocks.append(
            ContextBlock(
                key="system",
                title="System instructions",
                priority=0,
                max_tokens=sys_budget,
                text=system_instructions.strip(),
            )
        )
    blocks.append(
        ContextBlock(
            key="task",
            title="Current task",
            priority=1,
            max_tokens=task_budget,
            text=f"User request:\n{question.strip()}",
        )
    )

    if active_file_path or active_file_text:
        file_header = f"Active file: {active_file_path or '(unknown)'}\n"
        blocks.append(
            ContextBlock(
                key="active_file",
                title="Active file",
                priority=2,
                max_tokens=file_budget,
                text=(file_header + (active_file_text or "")).strip(),
            )
        )

    if related_files:
        parts: List[str] = []
        for p, content in related_files:
            parts.append(f"\n--- Related file: {p} ---\n{content}")
        blocks.append(
            ContextBlock(
                key="related_files",
                title="Related files (structural proximity)",
                priority=3,
                max_tokens=related_budget,
                text="\n".join(parts).strip(),
            )
        )

    if recent_edits:
        blocks.append(
            ContextBlock(
                key="recent_edits",
                title="Recent edits (recency working set)",
                priority=4,
                max_tokens=recent_budget,
                text="\n\n".join([t for t in recent_edits if t]).strip(),
            )
        )

    if errors_text:
        blocks.append(
            ContextBlock(
                key="errors",
                title="Errors / diagnostics",
                priority=5,
                max_tokens=err_budget,
                text=errors_text.strip(),
            )
        )

    # Retrieval over dumping: keep only top few chunks, and diversity-filter.
    docs_items = _dedupe_by_signature([(str(i), t) for i, t in enumerate(retrieved_docs[:5])])
    code_items = _dedupe_by_signature([(str(i), t) for i, t in enumerate(retrieved_code[:5])])
    knowledge_parts: List[str] = []
    if docs_items:
        knowledge_parts.append("=== Retrieved documentation ===")
        knowledge_parts.extend([t for _, t in docs_items])
    if code_items:
        knowledge_parts.append("=== Retrieved project code ===")
        knowledge_parts.extend([t for _, t in code_items])
    if knowledge_parts:
        blocks.append(
            ContextBlock(
                key="knowledge",
                title="Retrieved knowledge",
                priority=6,
                max_tokens=know_budget,
                text="\n".join(knowledge_parts).strip(),
            )
        )

    if optional_extras:
        blocks.append(
            ContextBlock(
                key="extras",
                title="Optional extras",
                priority=7,
                max_tokens=extra_budget,
                text="\n".join([e for e in optional_extras if e]).strip(),
            )
        )

    # Sort by priority (stable).
    blocks.sort(key=lambda b: b.priority)
    return blocks


def blocks_to_user_content(
    blocks: List[ContextBlock],
    limit: Optional[int] = None,
    reserve: int = 4096,
) -> Tuple[str, Dict[str, Any]]:
    """
    Trim each block to its budget; drop lowest-priority blocks until total <= target_cap.
    target_cap = limit - reserve (for tools + completion). If limit is None, only per-block
    trimming is applied and the previous behavior (cap at sum of max_tokens) is used.
    Returns (user_content, debug_info).
    """
    rendered: List[str] = []
    debug: Dict[str, Any] = {"blocks": []}
    target_cap: Optional[int] = None
    if limit is not None and limit > reserve:
        target_cap = limit - reserve

    for b in blocks:
        fitted, mode = fit_block_text(b.text, b.max_tokens)
        debug["blocks"].append(
            {
                "key": b.key,
                "title": b.title,
                "max_tokens": b.max_tokens,
                "estimated_tokens": estimate_tokens(fitted),
                "mode": mode,
                "included": True,
            }
        )
        if fitted:
            rendered.append(f"\n## {b.title}\n{fitted}\n")

    combined = "\n".join(rendered).strip()
    total_est = estimate_tokens(combined)
    debug["estimated_total_tokens"] = total_est

    # Hard cap: drop blocks from end until under target_cap (or under sum of max_tokens if no limit).
    cap = target_cap if target_cap is not None else sum(b.max_tokens for b in blocks)
    while len(rendered) > 1 and total_est > cap:
        rendered.pop()
        combined = "\n".join(rendered).strip()
        total_est = estimate_tokens(combined)
        debug["estimated_total_tokens"] = total_est

    return combined, debug


def _safe_join(root_abs: str, res_path: str) -> str:
    # User explicitly requested no restrictions; still normalize slashes.
    rp = res_path.replace("\\", "/")
    if rp.startswith("res://"):
        rp = rp[len("res://") :]
    return os.path.abspath(os.path.join(root_abs, rp))


def read_project_file(project_root_abs: str, res_path: str, max_bytes: int = 200_000) -> Optional[str]:
    try:
        abs_path = _safe_join(project_root_abs, res_path)
        with open(abs_path, "rb") as f:
            data = f.read(max_bytes + 1)
        if len(data) > max_bytes:
            data = data[:max_bytes] + b"\n\n[...truncated file read...]\n"
        return data.decode("utf-8", errors="replace")
    except Exception:
        return None


def list_project_files(
    project_root_abs: str,
    res_path: str = "res://",
    recursive: bool = True,
    extensions: Optional[List[str]] = None,
    max_entries: int = 500,
) -> List[str]:
    """
    List file paths under project_root_abs under res_path (res:// or res://subdir).
    Returns res://-prefixed paths. Skips .godot. extensions e.g. ['.svg'] (with or without leading dot).
    """
    if not project_root_abs or not os.path.isdir(project_root_abs):
        return []
    rp = res_path.replace("\\", "/").strip()
    if rp.startswith("res://"):
        rp = rp[len("res://") :].lstrip("/")
    root = os.path.abspath(os.path.join(project_root_abs, rp))
    if not root.startswith(os.path.abspath(project_root_abs)):
        return []
    exts = set()
    if extensions:
        for e in extensions:
            e = (e or "").strip().lower()
            if e and not e.startswith("."):
                e = "." + e
            if e:
                exts.add(e)
    out: List[str] = []

    def walk(dir_abs: str, dir_res: str) -> None:
        if len(out) >= max_entries:
            return
        try:
            entries = os.listdir(dir_abs)
        except OSError:
            return
        for name in sorted(entries):
            if len(out) >= max_entries:
                return
            if name.startswith(".") and name == ".godot":
                continue
            child_abs = os.path.join(dir_abs, name)
            child_res = (dir_res + "/" + name) if dir_res else name
            if os.path.isdir(child_abs):
                if recursive:
                    walk(child_abs, child_res)
                continue
            if exts:
                ext = "." + (os.path.splitext(name)[1] or "").lower()
                if ext not in exts:
                    continue
            out.append("res://" + child_res.replace("\\", "/"))

    start_res = rp.replace("\\", "/") if rp else ""
    if os.path.isdir(root):
        walk(root, start_res)
    return out


_RE_RES_PATH = re.compile(r'res://[^"\'\s\)]+')


def extract_structural_deps(text: str) -> List[str]:
    """
    Heuristic dependency extraction (locality-first):
    - GDScript: preload/load/extends "res://...", ResourceLoader.load("res://...")
    - Shaders: #include "res://..."
    """
    if not text:
        return []
    found = _RE_RES_PATH.findall(text)
    # Preserve order, unique.
    seen: set[str] = set()
    out: List[str] = []
    for p in found:
        if p in seen:
            continue
        seen.add(p)
        out.append(p)
    return out


def build_related_files_context(
    *,
    project_root_abs: str,
    active_file_res_path: str,
    active_file_text: str,
    max_files: int = 4,
) -> List[Tuple[str, str]]:
    """
    One-hop structural proximity: include repo-index-derived related files.
    Returns list of (res_path, content).
    """
    # Ensure index is reasonably fresh. We index incrementally, so calling this
    # per request is acceptable for local/dev usage.
    try:
        index_repo(project_root_abs=project_root_abs, reason="context_builder")
    except Exception:
        # If indexing fails, fall back to the legacy heuristic approach.
        deps = extract_structural_deps(active_file_text)
        related: List[Tuple[str, str]] = []
        for p in deps:
            if len(related) >= max_files:
                break
            if p == active_file_res_path:
                continue
            content = read_project_file(project_root_abs, p)
            if content:
                related.append((p, content))
        return related

    deps = get_related_res_paths(
        project_root_abs=project_root_abs,
        active_file_res_path=active_file_res_path,
        max_outbound=max(8, max_files * 3),
        max_inbound=max(4, max_files),
    )

    related: List[Tuple[str, str]] = []
    for p in deps:
        if len(related) >= max_files:
            break
        content = read_project_file(project_root_abs, p)
        if content:
            related.append((p, content))
    return related

