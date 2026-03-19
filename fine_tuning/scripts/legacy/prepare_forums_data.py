#!/usr/bin/env python3
"""
Prepare forum-style Q&A data from the Godot subreddit into JSONL.

Goal:
- Scrape top Godot help threads from Reddit (e.g. r/godot) and store them in a
  simple, LLM-friendly JSONL format under fine_tuning/data/forums/.

Constraints / design:
- We DO NOT hardcode your Reddit credentials. Instead, we expect:
    REDDIT_CLIENT_ID
    REDDIT_CLIENT_SECRET
    REDDIT_USER_AGENT
  to be set in the environment (or a .env that you load before running).
- We only fetch:
  - Subreddit: r/godot  (change via --subreddit if desired)
  - Sorting:  top of LAST YEAR (Reddit "top" with time_filter="year")
  - Filter:   posts with flair text containing "help" (case-insensitive), OR
              title containing "help" if flair is missing.
  - And:      posts with num_comments >= min_comments (default: 10).

Output JSONL (one thread per line):
  {
    "subreddit": "godot",
    "id": "abc123",
    "title": "...",
    "url": "https://reddit.com/...",
    "score": 123,
    "num_comments": 42,
    "created_utc": 1730000000.0,
    "messages": [
      {"role": "user", "author": "OP_NAME", "content": "<post selftext or link>"},
      {"role": "assistant", "author": "commenter1", "content": "<top-level comment body>"},
      {"role": "assistant", "author": "commenter2", "content": "<another top-level comment>"},
      ...
    ]
  }

This is intentionally simple: original post is treated as a "user" message;
top-level comments are treated as "assistant-like" responses. You can refine
the mapping later (e.g. pick best comment only, or structure multi-turn).
"""
import argparse
import os
import sys
from pathlib import Path
from typing import List, Dict, Any

try:
    import praw
    from praw.models import Submission
except ImportError:
    praw = None  # type: ignore[assignment]

import json


REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "fine_tuning" / "data"
OUT_DIR = DATA_DIR / "forums"
OUT_PATH = OUT_DIR / "godot_reddit_help.jsonl"


def make_reddit_client() -> "praw.Reddit":
    if praw is None:
        sys.stderr.write("praw is not installed. Run: pip install praw\n")
        sys.exit(1)
    client_id = os.environ.get("REDDIT_CLIENT_ID")
    client_secret = os.environ.get("REDDIT_CLIENT_SECRET")
    user_agent = os.environ.get("REDDIT_USER_AGENT", "godot-llm-scraper/0.1")
    if not client_id or not client_secret:
        sys.stderr.write(
            "Set REDDIT_CLIENT_ID and REDDIT_CLIENT_SECRET (and optionally REDDIT_USER_AGENT) "
            "before running this script.\n"
        )
        sys.exit(1)
    return praw.Reddit(
        client_id=client_id,
        client_secret=client_secret,
        user_agent=user_agent,
    )


def flair_or_title_has_help(sub: Submission) -> bool:
    """Return True if the post looks like a 'help' thread."""
    flair = (sub.link_flair_text or "").lower() if getattr(sub, "link_flair_text", None) else ""
    title = (sub.title or "").lower()
    if "help" in flair:
        return True
    if "help" in title:
        return True
    return False


def submission_to_record(sub: Submission, min_comment_body_len: int = 10) -> Dict[str, Any]:
    """Convert a Reddit submission + its top-level comments into our JSON shape."""
    messages: List[Dict[str, Any]] = []

    # Original post
    body = (sub.selftext or "").strip()
    if not body and sub.url:
        body = f"(link post) {sub.url}"
    messages.append(
        {
            "role": "user",
            "author": str(sub.author) if sub.author else None,
            "content": body,
        }
    )

    # Load comments; replace "MoreComments" objects
    sub.comments.replace_more(limit=None)
    for top_level in sub.comments.list():
        if getattr(top_level, "is_root", False):
            text = (top_level.body or "").strip()
            if len(text) < min_comment_body_len:
                continue
            messages.append(
                {
                    "role": "assistant",
                    "author": str(top_level.author) if top_level.author else None,
                    "content": text,
                }
            )

    return {
        "subreddit": str(sub.subreddit),
        "id": sub.id,
        "title": sub.title,
        "url": f"https://www.reddit.com{sub.permalink}",
        "score": int(sub.score or 0),
        "num_comments": int(sub.num_comments or 0),
        "created_utc": float(sub.created_utc or 0.0),
        "messages": messages,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Scrape Godot Reddit help threads into JSONL")
    parser.add_argument("--subreddit", type=str, default="godot", help="Subreddit name (default: godot)")
    parser.add_argument(
        "--limit",
        type=int,
        default=500,
        help="Max number of posts to consider from 'top' (last year). Actual written threads may be fewer.",
    )
    parser.add_argument(
        "--min-comments",
        type=int,
        default=10,
        help="Minimum number of comments for a thread to be included.",
    )
    args = parser.parse_args()

    reddit = make_reddit_client()
    sub = reddit.subreddit(args.subreddit)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written = 0

    with open(OUT_PATH, "w", encoding="utf-8") as out_f:
        for submission in sub.top(time_filter="year", limit=args.limit):
            if not flair_or_title_has_help(submission):
                continue
            if int(submission.num_comments or 0) < args.min_comments:
                continue
            record = submission_to_record(submission)
            # Skip threads where the OP has no meaningful body and no comments
            if len(record.get("messages") or []) <= 1:
                continue
            out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
            written += 1

    print(f"Wrote {written} Reddit help threads to {OUT_PATH}")


if __name__ == "__main__":
    main()

