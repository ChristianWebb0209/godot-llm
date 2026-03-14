import os
from typing import Any, Dict, List, Optional, Tuple

import chromadb
from chromadb.utils import embedding_functions
from dotenv import load_dotenv
from pydantic import BaseModel


load_dotenv()


_chroma_client: Optional[chromadb.PersistentClient] = None
_docs_collection = None
_code_collection = None


def get_chroma_client() -> chromadb.PersistentClient:
    """
    Lazily create a persistent ChromaDB client pointing at ../chroma_db.
    Uses OpenAI embeddings if OPENAI_API_KEY is set, otherwise falls back to
    Chroma's default embedding behavior.
    """
    global _chroma_client, _docs_collection, _code_collection
    if _chroma_client is not None:
        return _chroma_client

    db_root = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "chroma_db")
    )
    os.makedirs(db_root, exist_ok=True)

    _chroma_client = chromadb.PersistentClient(path=db_root)

    openai_api_key = os.getenv("OPENAI_API_KEY")
    openai_base_url = os.getenv("OPENAI_BASE_URL")
    embedding_fn = None
    if openai_api_key:
        embedding_fn = embedding_functions.OpenAIEmbeddingFunction(
            api_key=openai_api_key,
            model_name=os.getenv("OPENAI_EMBED_MODEL", "text-embedding-3-small"),
            api_base=openai_base_url or None,
        )

    # IMPORTANT: Avoid embedding function conflicts with existing collections.
    # If a collection already exists, reuse its configuration instead of
    # forcing a new embedding function, but log a warning if we *wanted*
    # to use OpenAI embeddings and can't.
    try:
        _docs_collection = _chroma_client.get_collection("docs")
        if embedding_fn is not None:
            from .console_log import yellow, dim
            print(yellow("chroma") + " " + dim("'docs' exists with different embedding; reusing."))
    except Exception:
        _docs_collection = _chroma_client.get_or_create_collection(
            name="docs", embedding_function=embedding_fn
        )

    try:
        _code_collection = _chroma_client.get_collection("project_code")
        if embedding_fn is not None:
            from .console_log import yellow, dim
            print(yellow("chroma") + " " + dim("'project_code' exists with different embedding; reusing."))
    except Exception:
        _code_collection = _chroma_client.get_or_create_collection(
            name="project_code", embedding_function=embedding_fn
        )

    return _chroma_client


def get_collections():
    get_chroma_client()
    return _docs_collection, _code_collection


class SourceChunk(BaseModel):
    id: str
    source_path: str
    score: float
    text_preview: str
    # metadata is expected to include at least:
    # - language: "gdscript" | "csharp"
    # - tags / role / importance
    metadata: Dict[str, Any] = {}


def _collect_top_docs(question: str, top_k: int) -> List[SourceChunk]:
    """
    Query the docs collection in ChromaDB for the most relevant documentation chunks.
    """
    _, docs_collection = get_collections()
    if docs_collection is None:
        return []

    try:
        results = docs_collection.query(
            query_texts=[question],
            n_results=top_k,
        )
    except Exception:
        return []

    docs: List[SourceChunk] = []
    ids = results.get("ids", [[]])[0]
    documents = results.get("documents", [[]])[0]
    metadatas = results.get("metadatas", [[]])[0]
    distances = results.get("distances", [[]])[0] or results.get("distances", [])

    for i, doc_id in enumerate(ids):
        meta = metadatas[i] if i < len(metadatas) and metadatas[i] else {}
        path = meta.get("path", "")
        score = float(distances[i]) if distances and i < len(distances) else 0.0
        docs.append(
            SourceChunk(
                id=str(doc_id),
                source_path=str(path),
                score=score,
                text_preview=documents[i] if i < len(documents) else "",
                metadata=meta,
            )
        )
    return docs


def _collect_code_results(
    question: str,
    language: Optional[str],
    top_k: int,
    importance_tiers: Tuple[float, float, float] = (0.6, 0.3, 0.0),
) -> List[SourceChunk]:
    """
    Query the project_code collection in ChromaDB, preferring high-importance
    snippets first, then gradually including lower-importance ones if needed.
    """
    code_collection, _ = get_collections()[1], get_collections()[0]  # type: ignore[index]
    if code_collection is None:
        return []

    all_results: List[SourceChunk] = []
    seen_ids: set[str] = set()

    for tier in importance_tiers:
        where: Dict[str, Any] = {"importance": {"$gte": tier}}
        if language:
            where["language"] = language

        try:
            results = code_collection.query(
                query_texts=[question],
                n_results=top_k,
                where=where,
            )
        except Exception:
            continue

        ids = results.get("ids", [[]])[0]
        documents = results.get("documents", [[]])[0]
        metadatas = results.get("metadatas", [[]])[0]
        distances = results.get("distances", [[]])[0] or results.get("distances", [])

        for i, code_id in enumerate(ids):
            if code_id in seen_ids:
                continue
            seen_ids.add(code_id)

            meta = metadatas[i] if i < len(metadatas) and metadatas[i] else {}
            path = meta.get("path", "")
            score = float(distances[i]) if distances and i < len(distances) else 0.0
            preview = documents[i] if i < len(documents) else ""

            all_results.append(
                SourceChunk(
                    id=str(code_id),
                    source_path=str(path),
                    score=score,
                    text_preview=preview,
                    metadata=meta,
                )
            )

        if len(all_results) >= top_k:
            break

    return all_results[:top_k]

