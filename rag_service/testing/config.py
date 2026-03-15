"""
Test harness config: backend URLs and model names for RAG vs Godot Composer.
Read from env so you can point at a running rag_service and override models.
"""
import os
from typing import Optional

# Base URL of the running RAG service (e.g. http://localhost:8000)
RAG_BASE_URL: str = os.getenv("RAG_BASE_URL", "http://127.0.0.1:8000").rstrip("/")

# Model used by POST /query (RAG + agent). Server default is gpt-4.1-mini if unset.
RAG_MODEL: Optional[str] = os.getenv("RAG_MODEL") or "gpt-4.1-mini"

# Model used by POST /composer/query (fine-tuned Godot Composer). Set in plugin or env.
COMPOSER_MODEL: Optional[str] = os.getenv("COMPOSER_MODEL") or os.getenv("OPENAI_MODEL") or "godot-composer"

# Endpoints (non-streaming for simpler test collection)
ENDPOINT_RAG: str = "/query"
ENDPOINT_COMPOSER: str = "/composer/query"

def get_rag_url() -> str:
    return f"{RAG_BASE_URL}{ENDPOINT_RAG}"

def get_composer_url() -> str:
    return f"{RAG_BASE_URL}{ENDPOINT_COMPOSER}"
