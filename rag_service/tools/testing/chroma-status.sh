#!/usr/bin/env bash

###############################################################################
# chroma-status.sh
#
# Show detailed status of the local ChromaDB used by the RAG system.
# - Activates rag_service/.venv
# - Connects to chroma_db/ (same root used by project/docs indexers)
# - Lists collections, document counts, and sample entries
# - Color-coded, verbose output
#
# Usage:
#   cd rag_service/tools/testing
#   bash chroma-status.sh
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAG_SERVICE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DB_ROOT="${RAG_SERVICE_DIR}/chroma_db"

LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
LOG_FILE="${LOG_DIR}/chroma_status_${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

# Colors
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"

step() {
  echo
  echo -e "${BOLD}${CYAN}========== [STEP] $* ==========${RESET}"
}

info() {
  echo -e "${BLUE}[info]${RESET} $*"
}

warn() {
  echo -e "${YELLOW}[warn]${RESET} $*"
}

error() {
  echo -e "${RED}[error]${RESET} $*"
}

success() {
  echo -e "${GREEN}[ok]${RESET} $*"
}

step "Paths and environment"
info "SCRIPT_DIR      = ${SCRIPT_DIR}"
info "RAG_SERVICE_DIR = ${RAG_SERVICE_DIR}"
info "DB_ROOT         = ${DB_ROOT}"

if [[ ! -d "${DB_ROOT}" ]]; then
  warn "ChromaDB root does not exist yet: ${DB_ROOT}"
  warn "You may need to run the docs indexer and project analyzer first."
fi

step "Activating virtualenv"
if [[ -f "${RAG_SERVICE_DIR}/.venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "${RAG_SERVICE_DIR}/.venv/bin/activate"
elif [[ -f "${RAG_SERVICE_DIR}/.venv/Scripts/activate" ]]; then
  # shellcheck disable=SC1091
  source "${RAG_SERVICE_DIR}/.venv/Scripts/activate"
else
  error "Could not find venv activate script under ${RAG_SERVICE_DIR}/.venv"
  exit 1
fi

python -V || { error "Python not available in venv"; exit 1; }

step "Inspecting ChromaDB"

python << 'PY'
import os
from pathlib import Path

import chromadb

DB_ROOT = Path(os.environ.get("DB_ROOT_OVERRIDE", "")) or Path(__file__).resolve().parent.parent.parent / "chroma_db"

print(f"\033[34m[info]\033[0m Using DB root: {DB_ROOT}")

if not DB_ROOT.exists():
    print(f"\033[33m[warn]\033[0m DB root does not exist yet. No collections to show.")
    raise SystemExit(0)

client = chromadb.PersistentClient(path=str(DB_ROOT))
collections = client.list_collections()

if not collections:
    print(f"\033[33m[warn]\033[0m No collections found in ChromaDB.")
    raise SystemExit(0)

print(f"\033[36m[info]\033[0m Found {len(collections)} collection(s):")

for coll in collections:
    name = coll.name
    try:
        count = coll.count()
    except Exception as e:
        print(f"  \033[31m[error]\033[0m Collection '{name}': failed to count documents: {e}")
        continue

    color = "\033[32m" if count > 0 else "\033[33m"
    print(f"  {color}{name}\033[0m - {count} document(s)")

    try:
        peek = coll.peek()
    except Exception as e:
        print(f"    \033[31m[error]\033[0m Failed to peek into '{name}': {e}")
        continue

    ids = (peek.get("ids") or [[]])[0]
    docs = (peek.get("documents") or [[]])[0]
    metas = (peek.get("metadatas") or [[]])[0]

    if not ids:
        print("    \033[2m(no sample documents)\033[0m")
        continue

    print(f"    Sample entries (up to 3):")
    for i, doc_id in enumerate(ids[:3]):
        meta = metas[i] if i < len(metas) and metas[i] else {}
        path = meta.get("path", "")
        importance = meta.get("importance")
        lang = meta.get("language")
        tags = meta.get("tags")

        print(f"      - id: {doc_id}")
        if path:
            print(f"        path: {path}")
        if lang:
            print(f"        language: {lang}")
        if importance is not None:
            print(f"        importance: {importance}")
        if tags:
            print(f"        tags: {tags}")

        # Show a short preview of the document
        if i < len(docs) and docs[i]:
            preview = docs[i].splitlines()
            snippet = "\n".join(preview[:3])
            print("        preview:")
            for line in snippet.splitlines():
                print(f"          {line}")

print("\033[32m[ok]\033[0m ChromaDB status inspection complete.")
PY

echo
success "ChromaDB status printed above. Full log: ${LOG_FILE}"

