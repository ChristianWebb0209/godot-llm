import json
import os
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import requests


BASE_URL = os.getenv("RAG_SERVICE_URL", "http://127.0.0.1:8000")


@dataclass
class ToolUsageTest:
    name: str
    question: str
    context_language: str = "gdscript"
    expect_tools: Optional[List[str]] = None  # None = just log, don't assert


TESTS: List[ToolUsageTest] = [
    ToolUsageTest(
        name="explicit_search_docs",
        question=(
            "Use your `search_docs` tool to find the official Godot documentation for "
            "CharacterBody2D movement and summarize the key points."
        ),
        expect_tools=["search_docs"],
    ),
    ToolUsageTest(
        name="explicit_search_project_code",
        question=(
            "Use your `search_project_code` tool to locate scripts related to player "
            "input handling (movement, jumping) in this project, then summarize how "
            "input is handled."
        ),
        expect_tools=["search_project_code"],
    ),
    ToolUsageTest(
        name="implicit_tools_player_movement",
        question=(
            "I'm not sure where player movement is implemented in my project. First, "
            "locate the most relevant scripts and then explain how movement works. "
            "If it helps, you may call any tools you have available."
        ),
        expect_tools=None,
    ),
    ToolUsageTest(
        name="implicit_tools_signals",
        question=(
            "Explain how to connect a button press signal to a function in Godot 4 "
            "using both the official docs and any relevant project examples. Use "
            "tools if they will improve your answer."
        ),
        expect_tools=None,
    ),
]


def _make_payload(test: ToolUsageTest) -> Dict[str, Any]:
    return {
        "question": test.question,
        "context": {
            "engine_version": "4.6",
            "language": test.context_language,
            "selected_node_type": "",
            "current_script": "",
            "extra": {},
        },
        "top_k": 5,
    }


def run_test(session: requests.Session, test: ToolUsageTest) -> None:
    url = f"{BASE_URL}/query"
    payload = _make_payload(test)
    print(f"\n=== Test: {test.name} ===")
    print(f"POST {url}")

    try:
        resp = session.post(url, json=payload, timeout=60)
    except Exception as e:  # pragma: no cover - diagnostic only
        print(f"[error] Request failed: {e}")
        return

    print(f"[info] HTTP {resp.status_code}")
    if resp.status_code != 200:
        print(f"[error] Non-200 response body:\n{resp.text}")
        return

    try:
        data = resp.json()
    except json.JSONDecodeError:
        print("[error] Failed to parse JSON response.")
        print(resp.text)
        return

    answer = data.get("answer", "")
    snippets = data.get("snippets", [])
    tool_calls = data.get("tool_calls", [])

    used_tool_names: List[str] = []
    for tc in tool_calls:
        if isinstance(tc, dict):
            name = tc.get("tool_name")
            if isinstance(name, str):
                used_tool_names.append(name)

    print(f"[info] tool_calls: {used_tool_names or '[]'}")
    print(f"[info] snippets returned: {len(snippets)}")

    # Print a short preview of the answer (first ~300 chars)
    preview = answer.strip().replace("\n", " ")[:300]
    print(f"[info] answer preview: {preview!r}")

    if test.expect_tools is not None:
        missing = [t for t in test.expect_tools if t not in used_tool_names]
        if missing:
            print(f"[WARN] Expected tools not used: {missing}")
        else:
            print(f"[OK] All expected tools were used: {test.expect_tools}")
    else:
        if used_tool_names:
            print(f"[OK] Model chose to use tools: {used_tool_names}")
        else:
            print("[INFO] Model did not use any tools for this test.")


def main() -> None:
    print(f"[info] Using RAG service base URL: {BASE_URL}")
    with requests.Session() as session:
        for test in TESTS:
            run_test(session, test)


if __name__ == "__main__":
    main()

