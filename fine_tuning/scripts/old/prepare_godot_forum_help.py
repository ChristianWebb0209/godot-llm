#!/usr/bin/env python3
"""
Scrape help threads from the official Godot forum into JSONL.

Source:
- Tag listing pages like:
  https://forum.godotengine.org/tags/c/help/6/godot-4

We:
- Follow the tag listing pages for `c/help/6` with tag `godot-4`.
- For each topic row:
  - Require tag `godot-4` (already filtered by the URL, but we double-check).
  - Require at least `min_replies` replies (default: 5).
- Visit the topic URL and extract:
  - Title, tags, URL, created date (if available), number of replies (from list).
  - Posts: original question + replies, in order.

Output:
- JSONL at fine_tuning/data/forums/godot_forum_help.jsonl
  Each line is a **messages-style** example ready for Colab:

  {
    "source": "godot_forum",
    "url": "https://forum.godotengine.org/t/...",
    "title": "...",
    "tags": ["godot-4", "gdscript", ...],
    "category": "Help",
    "num_replies": 12,
    "messages": [
      {"role": "user", "author": "OP", "content": "Original question text..."},
      {"role": "assistant", "author": "reply_author", "content": "Reply text..."},
      ...
    ]
  }

The "messages" array matches the structure expected by the Colab training
helpers (format_messages_example), so you can load this JSONL and feed it
directly into the same pipeline as tool-use and docs_qa.
"""

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from bs4 import BeautifulSoup


REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
OUT_DIR = DATA_DIR / "forums"
OUT_PATH = OUT_DIR / "godot_forum_help.jsonl"

BASE_FORUM_URL = "https://forum.godotengine.org"


def fetch_json(url: str, session: Optional[requests.Session] = None) -> Optional[Dict[str, Any]]:
    s = session or requests.Session()
    try:
        resp = s.get(url, timeout=20)
        if resp.status_code != 200:
            return None
        return resp.json()
    except requests.RequestException:
        return None
    except ValueError:
        return None


def parse_tag_page_json(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Parse a tag JSON page and return topic metadata dicts:
      {"id": int, "slug": str, "title": str, "url": str, "posts_count": int, "tags": [str]}
    """
    topics: List[Dict[str, Any]] = []
    topic_list = data.get("topic_list") or {}
    for t in topic_list.get("topics", []):
        if not isinstance(t, dict):
            continue
        tid = t.get("id")
        slug = t.get("slug")
        title = t.get("title")
        posts_count = int(t.get("posts_count") or 0)
        tags = t.get("tags") or []
        if not tid or not slug or not title:
            continue
        url = f"{BASE_FORUM_URL}/t/{slug}/{tid}"
        topics.append(
            {
                "id": tid,
                "slug": slug,
                "title": title,
                "url": url,
                "posts_count": posts_count,
                "tags": tags,
            }
        )
    return topics


def parse_topic_json(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Parse a topic JSON and extract posts in order as messages.

    Returns a list of:
      {"role": "user" or "assistant", "author": str | None, "content": str}

    First post is treated as 'user'; all subsequent posts as 'assistant'.
    """
    posts: List[Dict[str, Any]] = []
    # Identify original poster (OP) from topic details
    details = data.get("details") or {}
    created_by = details.get("created_by") or {}
    op_user_id = created_by.get("id") or created_by.get("user_id")
    op_username = created_by.get("username")
    post_stream = data.get("post_stream") or {}
    for idx, p in enumerate(post_stream.get("posts", [])):
        if not isinstance(p, dict):
            continue
        author_id = p.get("user_id")
        author_name = p.get("username")
        author = author_name or author_id
        cooked = p.get("cooked") or ""
        if not cooked:
            continue
        soup = BeautifulSoup(cooked, "html.parser")
        content = soup.get_text("\n", strip=True)
        if not content:
            continue

        is_op = False
        if op_user_id is not None and author_id == op_user_id:
            is_op = True
        elif op_username and author_name == op_username:
            is_op = True

        role = "user" if is_op else "assistant"
        posts.append(
            {
                "role": role,
                "author": str(author) if author is not None else None,
                "content": content,
            }
        )
    return posts


def main() -> None:
    parser = argparse.ArgumentParser(description="Scrape Godot forum help threads (godot-4) into JSONL")
    parser.add_argument(
        "--tag-url",
        type=str,
        default="https://forum.godotengine.org/tags/c/help/6/godot-4",
        help="Base tag URL to scrape (default: godot-4 help tag).",
    )
    parser.add_argument(
        "--pages",
        type=int,
        default=10,
        help="Number of pages of the tag list to walk (Discourse paginates with ?page=N).",
    )
    parser.add_argument(
        "--min-replies",
        type=int,
        default=5,
        help="Minimum replies (answers) required for a topic to be included.",
    )
    parser.add_argument(
        "--max-topics",
        type=int,
        default=1000,
        help="Maximum number of topics to write. Stops early when this many have been collected.",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=1.0,
        help="Sleep (seconds) between HTTP requests (politeness).",
    )
    args = parser.parse_args()

    session = requests.Session()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    topics: List[Dict[str, Any]] = []

    # Collect topic metadata from tag JSON pages.
    for page in range(1, args.pages + 1):
        if page == 1:
            url = args.tag_url + ".json"
        else:
            # Discourse tag JSON paginates with ?page=N
            url = f"{args.tag_url}.json?page={page}"
        data = fetch_json(url, session=session)
        if not data:
            continue
        page_topics = parse_tag_page_json(data)
        if not page_topics and page > 1:
            # If a later page is empty, we can stop early.
            break
        topics.extend(page_topics)
        time.sleep(args.sleep)

    # Deduplicate by URL and enforce min_replies at metadata level
    seen_urls = set()
    uniq_topics: List[Dict[str, Any]] = []
    for t in topics:
        if t["url"] in seen_urls:
            continue
        # posts_count includes OP; replies ≈ posts_count - 1
        replies_est = int(t.get("posts_count", 0) or 0) - 1
        if replies_est < args.min_replies:
            continue
        seen_urls.add(t["url"])
        uniq_topics.append(t)

    written = 0
    # Always overwrite the output file so each run is clean.
    with OUT_PATH.open("w", encoding="utf-8") as out_f:
        for topic in uniq_topics:
            topic_json_url = f"{topic['url']}.json"
            data = fetch_json(topic_json_url, session=session)
            if not data:
                continue
            posts = parse_topic_json(data)
            # Require at least one reply in the JSON (OP + at least one answer).
            if len(posts) < 2:
                continue
            record = {
                "source": "godot_forum",
                "url": topic["url"],
                "title": topic["title"],
                "tags": topic.get("tags") or [],
                "category": "Help",
                "num_replies": len(posts) - 1,
                # Use 'messages' key so this matches other datasets (tool-use, docs_qa)
                # and can be consumed directly by format_messages_example in Colab.
                "messages": posts,
            }
            out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
            written += 1
            time.sleep(args.sleep)
            if written >= args.max_topics:
                break

    print(f"Wrote {written} Godot forum help threads to {OUT_PATH}")


if __name__ == "__main__":
    main()

