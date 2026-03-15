import argparse
import os
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import chromadb
from chromadb.utils import embedding_functions
from dotenv import load_dotenv


# Rough upper bound on characters per chunk to stay well under
# OpenAI embedding models' per-input context limits. This is intentionally
# conservative: at ~4 characters per token, 6k chars ≈ 1.5k tokens.
MAX_DOC_CHARS = 6_000

# Approximate upper bound on total tokens per add() batch, to avoid
# hitting the OpenAI "max tokens per request" limit (300k). We use a
# safety margin below the hard limit.
MAX_BATCH_TOKENS_EST = 250_000

# Final hard cap on characters actually sent to the embedding API per
# record, as a last-resort safety guard against any missed edge cases.
HARD_MAX_EMBED_CHARS = 8_000


def _estimate_tokens(text: str) -> int:
    # Very rough heuristic: ~4 characters per token.
    return max(1, len(text) // 4)


def log(msg: str) -> None:
    print(msg)


def get_chroma_client() -> chromadb.PersistentClient:
    """
    Create a persistent Chroma client pointing at rag_service/data/chroma_db
    (same convention as the project parser and backend).
    """
    # Ensure .env is loaded so OPENAI_ env vars are visible here as well.
    load_dotenv()

    base = Path(__file__).resolve()
    db_root = (base.parent / ".." / ".." / ".." / "data" / "chroma_db").resolve()
    db_root.mkdir(parents=True, exist_ok=True)
    return chromadb.PersistentClient(path=str(db_root))


def get_docs_collection(client: chromadb.PersistentClient):
    """
    Return (or create) the 'docs' collection, using OpenAI embeddings if
    OPENAI_API_KEY is configured, mirroring the main app behavior.
    """
    openai_api_key = os.getenv("OPENAI_API_KEY")
    openai_base_url = os.getenv("OPENAI_BASE_URL")
    embedding_fn = None
    if openai_api_key:
        embedding_fn = embedding_functions.OpenAIEmbeddingFunction(
            api_key=openai_api_key,
            model_name=os.getenv("OPENAI_EMBED_MODEL", "text-embedding-3-small"),
            api_base=openai_base_url or None,
        )
    return client.get_or_create_collection("docs", embedding_function=embedding_fn)


def infer_engine_version(docs_root: Path, file_path: Path) -> Optional[str]:
    """
    Try to infer engine version from the path, e.g. docs/4.6/...
    Returns a string like '4.6' or None.
    """
    try:
        rel = file_path.relative_to(docs_root)
    except ValueError:
        return None
    # docs_root itself should be .../docs/4.6
    parts = docs_root.parts
    if len(parts) >= 1:
        tail = parts[-1]
        if any(ch.isdigit() for ch in tail):
            return tail
    return None


def _extract_heading_title(line: str) -> str:
    """
    Best-effort extraction of a heading title from a markdown heading line like:
      '## Foo bar[](#anchor "Link")'
    """
    stripped = line.lstrip("#").strip()
    bracket = stripped.find("[")
    if bracket != -1:
        stripped = stripped[:bracket].rstrip()
    return stripped


def _split_markdown_into_chunks(
    text: str, max_chars: int
) -> List[Tuple[str, Optional[str], Optional[str]]]:
    """
    Split a large markdown document into smaller chunks, trying to respect
    sections (##) and subsections (###). Falls back to fixed-size splits if
    necessary.

    Returns a list of (chunk_text, section_title, subsection_title).
    """
    if len(text) <= max_chars:
        return [(text, None, None)]

    lines = text.splitlines(keepends=True)

    # Separate optional frontmatter (starting/ending with ---).
    frontmatter_lines: List[str] = []
    body_start = 0
    if lines and lines[0].startswith("---"):
        # Find the terminating '---' line.
        for i in range(1, len(lines)):
            if lines[i].startswith("---"):
                # Include both boundary lines in the frontmatter.
                frontmatter_lines = lines[: i + 1]
                body_start = i + 1
                break
    frontmatter = "".join(frontmatter_lines)
    body_lines = lines[body_start:]

    def make_fixed_chunks(
        base_lines: List[str],
        section_title: Optional[str],
        subsection_title: Optional[str],
    ) -> List[Tuple[str, Optional[str], Optional[str]]]:
        body_text = "".join(base_lines)
        chunks: List[Tuple[str, Optional[str], Optional[str]]] = []
        for i in range(0, len(body_text), max_chars):
            slice_text = body_text[i : i + max_chars]
            chunks.append((frontmatter + slice_text, section_title, subsection_title))
        return chunks

    # Find sections (## headings).
    section_indices: List[int] = []
    for idx, line in enumerate(body_lines):
        stripped = line.lstrip()
        if stripped.startswith("## "):
            section_indices.append(idx)

    # If there are no sections, just fixed-size split the whole body.
    if not section_indices:
        return make_fixed_chunks(body_lines, None, None)

    chunks: List[Tuple[str, Optional[str], Optional[str]]] = []

    # Content before the first section gets attached to the first section.
    pre_section_lines = body_lines[: section_indices[0]]

    for s_idx, sec_start in enumerate(section_indices):
        sec_end = section_indices[s_idx + 1] if s_idx + 1 < len(section_indices) else len(
            body_lines
        )
        sec_lines = body_lines[sec_start:sec_end]

        # Attach any pre-section content to the first section only.
        if s_idx == 0 and pre_section_lines:
            sec_lines = pre_section_lines + sec_lines

        section_title = _extract_heading_title(sec_lines[0]) if sec_lines else None

        # If this section is already small enough, use it as a single chunk.
        sec_text = "".join(sec_lines)
        if len(frontmatter) + len(sec_text) <= max_chars:
            chunks.append((frontmatter + sec_text, section_title, None))
            continue

        # Try splitting by subsections (###) within this section.
        sub_indices: List[int] = []
        for idx, line in enumerate(sec_lines):
            stripped = line.lstrip()
            if stripped.startswith("### "):
                sub_indices.append(idx)

        # If no subsections, fall back to fixed-size chunks for this section.
        if not sub_indices:
            chunks.extend(make_fixed_chunks(sec_lines, section_title, None))
            continue

        # Content before the first subsection stays with the first subsection.
        pre_sub_lines = sec_lines[: sub_indices[0]]

        for sub_idx, sub_start in enumerate(sub_indices):
            sub_end = (
                sub_indices[sub_idx + 1] if sub_idx + 1 < len(sub_indices) else len(sec_lines)
            )
            sub_lines = sec_lines[sub_start:sub_end]

            if sub_idx == 0 and pre_sub_lines:
                sub_lines = pre_sub_lines + sub_lines

            subsection_title = _extract_heading_title(sub_lines[0]) if sub_lines else None
            sub_text = "".join(sub_lines)

            if len(frontmatter) + len(sub_text) <= max_chars:
                chunks.append((frontmatter + sub_text, section_title, subsection_title))
            else:
                # Still too big: final fallback to fixed-size chunks.
                chunks.extend(make_fixed_chunks(sub_lines, section_title, subsection_title))

    return chunks


def index_docs(
    docs_root: Path,
    dry_run: bool = False,
    batch_size: int = 64,
) -> None:
    """
    Walk docs_root (e.g. godot_knowledge_base/docs/4.6) and index all .md
    files into the 'docs' collection in ChromaDB.

    Each document:
      - id: relative path from docs_root (POSIX)
      - document: full markdown text
      - metadata: { path, engine_version }
    """
    if not docs_root.exists():
        raise RuntimeError(f"Docs root does not exist: {docs_root}")

    client = get_chroma_client()

    # Start from scratch: drop any existing 'docs' collection, then recreate.
    try:
        for coll in client.list_collections():
            if coll.name == "docs":
                log("[docs-index] Deleting existing 'docs' collection to reindex from scratch...")
                client.delete_collection("docs")
                break
    except Exception as e:
        log(f"[docs-index] WARNING: failed to list/delete existing collections: {e}")

    collection = get_docs_collection(client)

    md_files: List[Path] = sorted(docs_root.rglob("*.md"))
    log(f"[docs-index] Found {len(md_files)} markdown files under {docs_root}")

    if dry_run:
        for p in md_files[:10]:
            log(f"[docs-index] DRY RUN example file: {p}")
        return

    ids_batch: List[str] = []
    docs_batch: List[str] = []
    metas_batch: List[Dict[str, object]] = []
    current_batch_tokens = 0

    def flush_batch() -> None:
        nonlocal ids_batch, docs_batch, metas_batch, current_batch_tokens
        if not ids_batch:
            return

        # Final safety: ensure no single document exceeds the hard cap.
        for i, doc in enumerate(docs_batch):
            if len(doc) > HARD_MAX_EMBED_CHARS:
                original_len = len(doc)
                docs_batch[i] = doc[:HARD_MAX_EMBED_CHARS]
                log(
                    "[docs-index] WARNING: Truncating document in batch from "
                    f"{original_len} chars to {HARD_MAX_EMBED_CHARS} chars "
                    "to satisfy embedding model hard limits."
                )

        log(f"[docs-index] Adding batch of {len(ids_batch)} docs to ChromaDB...")
        collection.add(ids=ids_batch, documents=docs_batch, metadatas=metas_batch)
        ids_batch = []
        docs_batch = []
        metas_batch = []
        current_batch_tokens = 0

    total = 0
    for path in md_files:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception as e:
            log(f"[docs-index] Skipping {path} due to read error: {e}")
            continue

        rel = path.relative_to(docs_root).as_posix()
        engine_version = infer_engine_version(docs_root, path)

        # For large documents, split into section/subsection-based chunks
        # so we preserve all content without exceeding embedding limits.
        if len(text) > MAX_DOC_CHARS:
            chunks = _split_markdown_into_chunks(text, MAX_DOC_CHARS)
            log(
                f"[docs-index] Splitting oversized document {path} into "
                f"{len(chunks)} chunks for indexing."
            )
            for idx, (chunk_text, section_title, subsection_title) in enumerate(chunks, start=1):
                if not chunk_text.strip():
                    # Skip completely empty chunks (can happen with some
                    # pathological splits or docs with lots of separators).
                    continue

                chunk_id = f"{rel}#chunk-{idx}"
                est_tokens = _estimate_tokens(chunk_text)

                if (
                    ids_batch
                    and (len(ids_batch) >= batch_size
                         or current_batch_tokens + est_tokens > MAX_BATCH_TOKENS_EST)
                ):
                    flush_batch()

                ids_batch.append(chunk_id)
                docs_batch.append(chunk_text)
                current_batch_tokens += est_tokens

                meta: Dict[str, object] = {"path": rel, "chunk_index": idx}
                if engine_version:
                    meta["engine_version"] = engine_version
                if section_title:
                    meta["section"] = section_title
                if subsection_title:
                    meta["subsection"] = subsection_title
                metas_batch.append(meta)
                total += 1

                if len(ids_batch) >= batch_size:
                    flush_batch()
            continue

        if not text.strip():
            # Skip completely empty documents.
            continue

        est_tokens = _estimate_tokens(text)

        if (
            ids_batch
            and (len(ids_batch) >= batch_size
                 or current_batch_tokens + est_tokens > MAX_BATCH_TOKENS_EST)
        ):
            flush_batch()

        ids_batch.append(rel)
        docs_batch.append(text)
        current_batch_tokens += est_tokens
        meta: Dict[str, object] = {"path": rel}
        if engine_version:
            meta["engine_version"] = engine_version
        metas_batch.append(meta)
        total += 1

        if len(ids_batch) >= batch_size:
            flush_batch()

    flush_batch()
    log(f"[docs-index] Indexed {total} documents into 'docs' collection.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Index scraped Godot documentation into ChromaDB for RAG. "
            "Walks a docs root (default: godot_knowledge_base/docs/4.6) and "
            "adds each .md file to the 'docs' collection."
        )
    )
    parser.add_argument(
        "--docs-root",
        type=str,
        help=(
            "Root of scraped docs. "
            "Defaults to ../../../godot_knowledge_base/docs/4.6 relative to this script."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List some files that would be indexed but do not write to ChromaDB.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=64,
        help="Number of documents per ChromaDB add() call (default: 64).",
    )

    args = parser.parse_args()

    if args.docs_root:
        docs_root = Path(args.docs_root).expanduser().resolve()
    else:
        base = Path(__file__).resolve()
        docs_root = (base.parent / ".." / ".." / ".." / "godot_knowledge_base" / "docs" / "4.6").resolve()

    log(f"[docs-index] Using docs root: {docs_root}")
    index_docs(docs_root=docs_root, dry_run=args.dry_run, batch_size=args.batch_size)


if __name__ == "__main__":
    main()

