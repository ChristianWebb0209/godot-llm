import json
import os
from typing import Any, Dict, List, Optional, Tuple

import chromadb
from chromadb.utils import embedding_functions
from dotenv import load_dotenv
from openai import OpenAI
from fastapi import FastAPI, Request
from pydantic import BaseModel

from .services.tools import (
    dispatch_tool_call,
    get_openai_tools_payload,
    get_registered_tools,
)


load_dotenv()  # Load environment variables from .env if present.

app = FastAPI(title="Godot RAG Service", version="0.1.0")


# --- ChromaDB setup ---

_chroma_client: Optional[chromadb.PersistentClient] = None
_docs_collection = None
_code_collection = None
_openai_client: Optional[OpenAI] = None


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

    _docs_collection = _chroma_client.get_or_create_collection(
        name="docs", embedding_function=embedding_fn
    )
    _code_collection = _chroma_client.get_or_create_collection(
        name="project_code", embedding_function=embedding_fn
    )

    return _chroma_client


def get_collections():
    get_chroma_client()
    return _docs_collection, _code_collection


def get_openai_client() -> Optional[OpenAI]:
    """
    Lazily create an OpenAI client using environment variables.
    Returns None if no OPENAI_API_KEY is configured.
    """
    global _openai_client
    if _openai_client is not None:
        return _openai_client

    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        return None

    base_url = os.getenv("OPENAI_BASE_URL")
    _openai_client = OpenAI(api_key=api_key, base_url=base_url or None)
    return _openai_client


class QueryContext(BaseModel):
    engine_version: Optional[str] = None
    # Preferred script language for answers, based on the active file.
    language: Optional[str] = None  # "gdscript" | "csharp"
    selected_node_type: Optional[str] = None
    current_script: Optional[str] = None
    extra: Dict[str, Any] = {}


class QueryRequest(BaseModel):
    question: str
    context: Optional[QueryContext] = None
    top_k: int = 5


class SourceChunk(BaseModel):
    id: str
    source_path: str
    score: float
    text_preview: str
    # metadata is expected to include at least:
    # - language: "gdscript" | "csharp"
    # - tags / role / importance
    metadata: Dict[str, Any] = {}


class QueryResponse(BaseModel):
    answer: str
    snippets: List[SourceChunk]


class ToolCallResult(BaseModel):
    tool_name: str
    arguments: Dict[str, Any]
    output: Any


class QueryResponseWithTools(QueryResponse):
    # Optional structured record of any tools the model asked us to run.
    tool_calls: List[ToolCallResult] = []


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


def _call_llm_with_rag(
    question: str,
    context_language: Optional[str],
    docs: List[SourceChunk],
    code_snippets: List[SourceChunk],
    is_obscure: bool,
) -> str:
    """
    Call OpenAI chat completions to synthesize an answer from retrieved docs/code.
    Falls back to a verbose plain-text template if no API key is configured.
    """
    client = get_openai_client()
    model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

    # Build a verbose reasoning-oriented answer if no LLM is available.
    if client is None:
        lines: List[str] = []
        lines.append("This answer is grounded in your Godot docs and project code.\n")
        lines.append(f"Question: {question}\n")
        if context_language:
            lines.append(f"Preferred language: {context_language}\n")
        if docs:
            lines.append("\nRelevant documentation snippets:\n")
            for d in docs:
                lines.append(f"- {d.source_path}")
        if code_snippets:
            lines.append("\nRelevant project code snippets (ordered by relevance/importance):\n")
            for s in code_snippets:
                tags = s.metadata.get("tags", [])
                importance = s.metadata.get("importance", 0.0)
                lines.append(
                    f"- {s.source_path} (importance={importance}, tags={tags})"
                )
        if is_obscure:
            lines.append(
                "\nNote: This appears to be a more niche area of your codebase, "
                "so lower-importance snippets were also considered."
            )
        return "\n".join(lines)

    # Build structured context for the LLM.
    docs_block_lines: List[str] = []
    for d in docs:
        docs_block_lines.append(
            f"[DOC] path={d.source_path} meta={d.metadata}\n{d.text_preview}\n"
        )
    code_block_lines: List[str] = []
    for s in code_snippets:
        code_block_lines.append(
            f"[CODE] path={s.source_path} meta={s.metadata}\n{s.text_preview}\n"
        )

    system_prompt = (
        "You are a Godot 4.x development assistant. "
        "You receive a user question plus retrieved documentation and real project code. "
        "Use ONLY the provided context to answer. Prefer higher-importance code snippets "
        "when multiple are relevant, but you may also rely on lower-importance snippets "
        "if the topic appears niche or under-documented. "
        "Always be explicit about your reasoning: explain which snippets you used "
        "and why, referencing them by their path. "
        "When writing code examples, default to the user's preferred language if given."
    )

    user_prompt_lines: List[str] = []
    user_prompt_lines.append(f"Question: {question}\n")
    if context_language:
        user_prompt_lines.append(f"Preferred language: {context_language}\n")
    if is_obscure:
        user_prompt_lines.append(
            "Heuristic: This seems like a more obscure area of the codebase; "
            "lower-importance snippets may also be relevant.\n"
        )
    if docs_block_lines:
        user_prompt_lines.append("\n=== Documentation Context ===\n")
        user_prompt_lines.extend(docs_block_lines)
    if code_block_lines:
        user_prompt_lines.append("\n=== Project Code Context ===\n")
        user_prompt_lines.extend(code_block_lines)
    user_prompt_lines.append(
        "\nPlease respond with:\n"
        "1) A concise answer.\n"
        "2) A short 'Reasoning' section explaining which docs/code you used and why.\n"
        "3) Code examples in the preferred language if applicable.\n"
    )

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": "\n".join(user_prompt_lines)},
    ]

    completion = client.chat.completions.create(
        model=model,
        messages=messages,
    )
    return completion.choices[0].message.content or ""


def _run_query_with_tools(
    question: str,
    context_language: Optional[str],
    top_k: int,
    max_tool_rounds: int = 3,
) -> Tuple[str, List[SourceChunk], List[ToolCallResult]]:
    """
    Orchestrate a full query using:
      - Initial RAG retrieval for docs + code.
      - OpenAI tool calls for follow-up operations (searching again, etc.).

    Returns (final_answer, snippets_used, tool_calls_run).
    """
    client = get_openai_client()
    # If there is no LLM, fall back to the existing RAG-only path.
    if client is None:
        docs = _collect_top_docs(question, top_k=top_k)
        code_snippets = _collect_code_results(
            question=question,
            language=context_language,
            top_k=top_k,
        )
        is_obscure = len(code_snippets) < max(1, top_k // 3)
        answer = _call_llm_with_rag(
            question=question,
            context_language=context_language,
            docs=docs,
            code_snippets=code_snippets,
            is_obscure=is_obscure,
        )
        return answer, docs + code_snippets, []

    # Initial RAG step.
    docs = _collect_top_docs(question, top_k=top_k)
    code_snippets = _collect_code_results(
        question=question,
        language=context_language,
        top_k=top_k,
    )
    is_obscure = len(code_snippets) < max(1, top_k // 3)

    # Build initial context message (similar to _call_llm_with_rag, but
    # now we allow the model to decide whether to invoke tools).
    docs_block_lines: List[str] = []
    for d in docs:
        docs_block_lines.append(
            f"[DOC] path={d.source_path} meta={d.metadata}\n{d.text_preview}\n"
        )
    code_block_lines: List[str] = []
    for s in code_snippets:
        code_block_lines.append(
            f"[CODE] path={s.source_path} meta={s.metadata}\n{s.text_preview}\n"
        )

    system_prompt = (
        "You are a Godot 4.x development assistant. "
        "You have access to:\n"
        "- Retrieved documentation and project code snippets.\n"
        "- A small set of backend tools you can call to refine your search.\n\n"
        "Use tools when they will significantly improve your answer "
        "(for example, to search again with a more specific query), "
        "but avoid unnecessary tool calls. When you are satisfied, "
        "return a final answer to the user."
    )

    user_prompt_lines: List[str] = []
    user_prompt_lines.append(f"Question: {question}\n")
    if context_language:
        user_prompt_lines.append(f"Preferred language: {context_language}\n")
    if is_obscure:
        user_prompt_lines.append(
            "Heuristic: This seems like a more obscure area of the codebase; "
            "lower-importance snippets may also be relevant.\n"
        )
    if docs_block_lines:
        user_prompt_lines.append("\n=== Documentation Context ===\n")
        user_prompt_lines.extend(docs_block_lines)
    if code_block_lines:
        user_prompt_lines.append("\n=== Project Code Context ===\n")
        user_prompt_lines.extend(code_block_lines)
    user_prompt_lines.append(
        "\nYou may call tools like 'search_docs' or 'search_project_code' to get "
        "more focused information if needed. If the existing context is enough, "
        "answer directly without calling tools.\n"
    )

    messages: List[Dict[str, Any]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": "\n".join(user_prompt_lines)},
    ]

    tools_payload = get_openai_tools_payload()
    model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

    tool_call_results: List[ToolCallResult] = []

    for _ in range(max_tool_rounds):
        response = client.responses.create(
            model=model,
            input=messages,
            tools=tools_payload,
        )

        # responses.create returns a top-level object; grab the first output.
        output = response.output[0] if getattr(response, "output", None) else None
        if not output:
            break

        # If the model returned tool calls, execute them and append results.
        tool_calls = getattr(output, "tool_calls", None) or []
        if tool_calls:
            for tc in tool_calls:
                if tc.type != "function":
                    continue
                fn = tc.function
                name = fn.name
                try:
                    args_dict = json.loads(fn.arguments or "{}")
                except Exception:
                    args_dict = {}

                tool_output = dispatch_tool_call(name, args_dict)
                tool_call_results.append(
                    ToolCallResult(
                        tool_name=name,
                        arguments=args_dict,
                        output=tool_output,
                    )
                )

                # Feed tool result back to the model.
                messages.append(
                    {
                        "role": "assistant",
                        "tool_calls": [
                            {
                                "type": "function",
                                "function": {
                                    "name": name,
                                    "arguments": json.dumps(args_dict),
                                },
                            }
                        ],
                    }
                )
                messages.append(
                    {
                        "role": "tool",
                        "name": name,
                        "content": json.dumps(tool_output),
                    }
                )
            # Continue loop: let the model see tool outputs and decide next.
            continue

        # No tool calls → we expect a final natural-language answer.
        if getattr(output, "message", None):
            final_content = output.message["content"]
            if isinstance(final_content, list):
                # responses API may return rich content; join text parts.
                text_parts = [
                    part.get("text", "") if isinstance(part, dict) else str(part)
                    for part in final_content
                ]
                answer = "".join(text_parts)
            else:
                answer = str(final_content)
            snippets = docs + code_snippets
            return answer, snippets, tool_call_results

        # Fallback: no tool calls and no message; break.
        break

    # If we exit the loop without a clean final answer, fall back to the
    # existing RAG-only answer builder.
    fallback_answer = _call_llm_with_rag(
        question=question,
        context_language=context_language,
        docs=docs,
        code_snippets=code_snippets,
        is_obscure=is_obscure,
    )
    return fallback_answer, docs + code_snippets, tool_call_results


@app.get("/health")
async def health() -> Dict[str, str]:
    """
    Simple health check so the Godot plugin can verify connectivity.
    """
    return {"status": "ok"}


@app.post("/query", response_model=QueryResponseWithTools)
async def query_rag(payload: QueryRequest, request: Request) -> QueryResponseWithTools:
    """
    RAG endpoint that:
    - Searches Godot docs (if indexed) in ChromaDB.
    - Searches project code in ChromaDB, preferring higher-importance snippets.
    - Expands to lower-importance code if the area looks more obscure
      (i.e. we don't find enough high-tier hits).
    """
    client_host = request.client.host if request.client else "unknown"
    print(f"[RAG] /query from {client_host}: {payload.question!r}")

    question = payload.question.strip()
    context_language = payload.context.language if payload.context else None

    answer, snippets, tool_calls = _run_query_with_tools(
        question=question,
        context_language=context_language,
        top_k=payload.top_k,
        max_tool_rounds=3,
    )

    return QueryResponseWithTools(
        answer=answer,
        snippets=snippets,
        tool_calls=tool_calls,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)

