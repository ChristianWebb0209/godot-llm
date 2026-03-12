#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# End-to-end RAG test runner
#
# - Activates the rag_service virtualenv
# - Starts the FastAPI backend (uvicorn) in the background
# - Waits for /health to be ready
# - Runs a series of curl tests against /query
# - Logs EVERYTHING (commands, outputs, errors) to a timestamped log file
#
# Usage:
#   cd rag_service/tools/testing
#   bash run_e2e_rag_tests.sh
#
# Requirements:
#   - venv at rag_service/.venv
#   - uvicorn + dependencies installed
#   - Optional: OPENAI_API_KEY etc in rag_service/.env (loaded by uvicorn)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RAG_SERVICE_DIR="${REPO_ROOT}"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
LOG_FILE="${LOG_DIR}/run_e2e_rag_tests_${TIMESTAMP}.log"

echo "[test] Logs will be written to: ${LOG_FILE}"

exec > >(tee -a "${LOG_FILE}") 2>&1

BACKEND_PID=""

cleanup() {
  echo "[test] Cleaning up..."
  if [[ -n "${BACKEND_PID}" ]]; then
    echo "[test] Stopping backend (PID=${BACKEND_PID})..."
    if kill "${BACKEND_PID}" 2>/dev/null; then
      echo "[test] Sent SIGTERM to backend."
    fi
  fi
}

trap cleanup EXIT

step() {
  echo
  echo "========== [STEP] $* =========="
}

fail() {
  echo
  echo "[FAIL] $*"
  echo "[FAIL] See log file for details: ${LOG_FILE}"
  exit 1
}

step "Verifying expected directories"
echo "[test] SCRIPT_DIR=${SCRIPT_DIR}"
echo "[test] REPO_ROOT=${REPO_ROOT}"
echo "[test] RAG_SERVICE_DIR=${RAG_SERVICE_DIR}"

if [[ ! -d "${RAG_SERVICE_DIR}/app" ]]; then
  fail "Could not find rag_service/app under ${RAG_SERVICE_DIR}"
fi

step "Activating virtualenv"
if [[ -f "${RAG_SERVICE_DIR}/.venv/bin/activate" ]]; then
  # Unix-style venv
  # shellcheck disable=SC1091
  source "${RAG_SERVICE_DIR}/.venv/bin/activate"
elif [[ -f "${RAG_SERVICE_DIR}/.venv/Scripts/activate" ]]; then
  # Windows venv (Git Bash / MSYS)
  # shellcheck disable=SC1091
  source "${RAG_SERVICE_DIR}/.venv/Scripts/activate"
else
  fail "Could not find venv activate script under ${RAG_SERVICE_DIR}/.venv"
fi

python -V || fail "Python not available in venv"

step "Validating OpenAI API key (if configured)"
python << 'PY'
import os
import sys

from openai import OpenAI

api_key = os.getenv("OPENAI_API_KEY")
model = os.getenv("OPENAI_MODEL", "gpt-4.1-mini")

if not api_key:
    print("[test-openai] OPENAI_API_KEY is not set. Skipping API validation (backend will fall back as needed).")
    sys.exit(0)

print(f"[test-openai] Testing OpenAI API key with model={model!r}...")

try:
    client = OpenAI(api_key=api_key, base_url=os.getenv("OPENAI_BASE_URL") or None)
    # Very small test call
    completion = client.chat.completions.create(
        model=model,
        messages=[{"role": "system", "content": "ping"}, {"role": "user", "content": "Say 'pong'"}],
        max_tokens=4,
    )
    text = completion.choices[0].message.content or ""
    print(f"[test-openai] Success. Sample response: {text!r}")
    sys.exit(0)
except Exception as e:
    msg = str(e)
    print(f"[test-openai] ERROR calling OpenAI: {msg}")
    # Common failure modes to highlight:
    if "invalid_api_key" in msg or "Incorrect API key" in msg:
        print("[test-openai] Detected invalid API key.")
    if "insufficient_quota" in msg or "insufficient_quota" in msg.lower():
        print("[test-openai] Detected insufficient credits / quota.")
    sys.exit(1)
PY


step "Starting backend (uvicorn) in background"
cd "${RAG_SERVICE_DIR}"

UVICORN_CMD=(python -m uvicorn app.main:app --host 0.0.0.0 --port 8000)
echo "[test] Command: ${UVICORN_CMD[*]}"

"${UVICORN_CMD[@]}" >> "${LOG_FILE}" 2>&1 &
BACKEND_PID=$!
echo "[test] Backend PID=${BACKEND_PID}"

step "Waiting for /health to become ready"
HEALTH_URL="http://127.0.0.1:8000/health"
MAX_ATTEMPTS=30
SLEEP_SECONDS=1
attempt=1

while (( attempt <= MAX_ATTEMPTS )); do
  echo "[test] Health check attempt ${attempt}/${MAX_ATTEMPTS}..."
  set +e
  HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_URL}")"
  CURL_EXIT=$?
  set -e
  if [[ "${CURL_EXIT}" -eq 0 && "${HTTP_CODE}" == "200" ]]; then
    echo "[test] Backend is healthy (HTTP 200)."
    break
  fi
  sleep "${SLEEP_SECONDS}"
  (( attempt++ ))
done

if (( attempt > MAX_ATTEMPTS )); then
  fail "Backend /health did not return 200 within ${MAX_ATTEMPTS} seconds."
fi

run_query() {
  local name="$1"
  local json_payload="$2"

  step "Running test: ${name}"
  echo "[test] Request payload:"
  echo "${json_payload}" | sed 's/^/[test]   /'

  local response_file
  response_file="$(mktemp)"

  set +e
  curl -s -o "${response_file}" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${json_payload}" \
    "http://127.0.0.1:8000/query" >"${response_file}.code"
  CURL_EXIT=$?
  set -e

  local http_code
  http_code="$(cat "${response_file}.code")"

  echo "[test] HTTP status: ${http_code}"
  if [[ "${CURL_EXIT}" -ne 0 ]]; then
    echo "[test] curl exit code: ${CURL_EXIT}"
    echo "[test] Raw response:"
    cat "${response_file}" || true
    fail "curl failed for test '${name}'."
  fi

  if [[ "${http_code}" != "200" ]]; then
    echo "[test] Non-200 response for test '${name}'. Body:"
    cat "${response_file}" || true
    fail "Unexpected HTTP ${http_code} for test '${name}'."
  fi

  echo "[test] Response for '${name}':"
  cat "${response_file}" || true
  echo

  rm -f "${response_file}" "${response_file}.code"
}

###############################################################################
# Actual tests
###############################################################################

run_query "Basic docs + code query (GDScript)" '{
  "question": "How do I implement a 2D player controller in Godot 4?",
  "context": {
    "engine_version": "4.2",
    "language": "gdscript",
    "selected_node_type": "CharacterBody2D",
    "current_script": "",
    "extra": {}
  },
  "top_k": 5
}'

run_query "C#-focused query" '{
  "question": "Show me how to handle input in a C# player controller.",
  "context": {
    "engine_version": "4.2",
    "language": "csharp",
    "selected_node_type": "",
    "current_script": "",
    "extra": {}
  },
  "top_k": 5
}'

run_query "Shader-related query" '{
  "question": "How can I create a burning fire shader effect in Godot?",
  "context": {
    "engine_version": "4.2",
    "language": "gdscript",
    "selected_node_type": "",
    "current_script": "",
    "extra": {}
  },
  "top_k": 5
}'

echo
echo "========== [SUCCESS] All RAG tests passed =========="
echo "[test] Full log: ${LOG_FILE}"

