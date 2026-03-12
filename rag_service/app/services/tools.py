from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

from ..main import SourceChunk, _collect_top_docs, _collect_code_results


@dataclass
class ToolDef:
    name: str
    description: str
    # JSON-schema-like parameters shape for OpenAI tools
    parameters: Dict[str, Any]
    # Backend implementation: (args_dict) -> result serializable to JSON
    handler: Callable[[Dict[str, Any]], Any]


def _tool_search_docs(args: Dict[str, Any]) -> Dict[str, Any]:
    query: str = args.get("query", "")
    top_k: int = int(args.get("top_k", 5))
    docs: List[SourceChunk] = _collect_top_docs(query, top_k=top_k)
    return {
        "results": [
            {
                "id": d.id,
                "path": d.source_path,
                "score": d.score,
                "metadata": d.metadata,
                "preview": d.text_preview,
            }
            for d in docs
        ]
    }


def _tool_search_project_code(args: Dict[str, Any]) -> Dict[str, Any]:
    query: str = args.get("query", "")
    language: Optional[str] = args.get("language") or None
    top_k: int = int(args.get("top_k", 5))
    snippets: List[SourceChunk] = _collect_code_results(
        question=query,
        language=language,
        top_k=top_k,
    )
    return {
        "results": [
            {
                "id": s.id,
                "path": s.source_path,
                "score": s.score,
                "metadata": s.metadata,
                "preview": s.text_preview,
            }
            for s in snippets
        ]
    }


def get_registered_tools() -> List[ToolDef]:
    """
    Return the list of tools available to the LLM.
    This is the single source of truth for backend-side tools for now.
    """
    return [
        ToolDef(
            name="search_docs",
            description="Search the indexed Godot documentation for relevant pages/snippets.",
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural language query or keywords to search in docs.",
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Maximum number of results to return.",
                        "default": 5,
                        "minimum": 1,
                        "maximum": 20,
                    },
                },
                "required": ["query"],
            },
            handler=_tool_search_docs,
        ),
        ToolDef(
            name="search_project_code",
            description=(
                "Search the indexed project_code collection for relevant scripts or shaders. "
                "Use this to locate concrete examples in the current project."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural language description or code keywords.",
                    },
                    "language": {
                        "type": "string",
                        "description": "Optional language filter: 'gdscript', 'csharp', or 'gdshader'.",
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Maximum number of results to return.",
                        "default": 5,
                        "minimum": 1,
                        "maximum": 20,
                    },
                },
                "required": ["query"],
            },
            handler=_tool_search_project_code,
        ),
        # Future: add Godot editor-facing tools here, e.g.:
        # - summarize_current_scene
        # - plan_editor_actions
    ]


def get_openai_tools_payload() -> List[Dict[str, Any]]:
    """
    Convert internal ToolDef objects into the 'tools' payload expected by
    OpenAI tool-calling APIs.
    """
    tools_payload: List[Dict[str, Any]] = []
    for t in get_registered_tools():
        tools_payload.append(
            {
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters,
                },
            }
        )
    return tools_payload


def dispatch_tool_call(name: str, arguments: Dict[str, Any]) -> Any:
    """
    Execute the backend implementation for a named tool.
    """
    for t in get_registered_tools():
        if t.name == name:
            return t.handler(arguments)
    raise ValueError(f"Unknown tool: {name}")

