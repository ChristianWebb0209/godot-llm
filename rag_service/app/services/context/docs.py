"""
Retrieved documentation: formatting and assembling docs + code snippets
into the single "knowledge" block (semantic search results from Chroma).
"""

from typing import List

from .budget import dedupe_by_signature
from .code_samples import SCRAPED_CODE_DISCLAIMER


def build_knowledge_block_parts(
    retrieved_docs: List[str],
    retrieved_code: List[str],
    max_docs: int = 8,
    max_code: int = 8,
) -> List[str]:
    """
    Dedupe and assemble doc + code snippets for the knowledge block.
    Returns a list of strings to join (with "=== Retrieved documentation ===" etc.).
    """
    docs_items = dedupe_by_signature([(str(i), t) for i, t in enumerate(retrieved_docs[:max_docs])])
    code_items = dedupe_by_signature([(str(i), t) for i, t in enumerate(retrieved_code[:max_code])])
    parts: List[str] = []
    if docs_items:
        parts.append(
            "=== Retrieved documentation ===\n"
            "(Official Godot manual/docs—authoritative for API and engine behavior.)"
        )
        parts.extend([t for _, t in docs_items])
    if code_items:
        parts.append(
            "=== Retrieved project code ===\n"
            "(From other indexed Godot repos, NOT the user's project—use as reference/patterns only.)"
        )
        parts.append(SCRAPED_CODE_DISCLAIMER.strip())
        parts.extend([t for _, t in code_items])
    return parts
