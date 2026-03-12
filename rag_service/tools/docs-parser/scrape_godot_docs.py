import argparse
import os
import re
import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set

import requests
from bs4 import BeautifulSoup, Tag
from markdownify import markdownify as html_to_md
from urllib.parse import urljoin, urldefrag, urlparse


GODOT_BASE_URL = "https://docs.godotengine.org/en/stable/"


@dataclass
class SectionMeta:
    id: str
    title: str
    subsections: List[str] = field(default_factory=list)


def is_docs_url(url: str, base: str) -> bool:
    """
    Return True if `url` is a Godot docs page under the given base and looks like HTML content.
    """
    parsed = urlparse(url)
    base_parsed = urlparse(base)
    if parsed.netloc != base_parsed.netloc:
        return False
    if not parsed.path.startswith(base_parsed.path):
        return False

    # Ignore non-HTML assets.
    if any(
        parsed.path.endswith(ext)
        for ext in (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".css", ".js", ".ico", ".ttf", ".woff", ".woff2")
    ):
        return False

    # Only crawl HTML pages.
    if parsed.path.endswith(".html") or parsed.path.endswith("/"):
        return True

    return False


def path_from_url(url: str, base: str, output_root: Path) -> Path:
    """
    Map a docs URL to a local Markdown path under output_root.

    Example:
    https://docs.godotengine.org/en/stable/about/list_of_features.html
      -> output_root / "about" / "list_of_features.md"
    """
    parsed = urlparse(url)
    base_parsed = urlparse(base)
    rel = parsed.path[len(base_parsed.path) :].lstrip("/")  # e.g. "about/list_of_features.html"
    if not rel:
        rel = "index.html"
    if rel.endswith("/"):
        rel = rel + "index.html"

    rel_path = Path(rel)
    stem = rel_path.stem or "index"
    return output_root.joinpath(rel_path.parent, f"{stem}.md")


def extract_sections(soup: BeautifulSoup) -> List[SectionMeta]:
    """
    Extract H2 sections and <strong> subsections from a docs page.
    """
    sections: List[SectionMeta] = []
    body = soup.find("div", {"role": "main"}) or soup.body
    if not body:
        return sections

    for h2 in body.find_all("h2"):
        title = h2.get_text(strip=True)
        section_id = h2.get("id") or re.sub(r"[^a-z0-9_]+", "-", title.lower())
        meta = SectionMeta(id=section_id, title=title)

        # Walk siblings until the next H2 to find <strong> subsections.
        sib = h2.next_sibling
        while sib and not (isinstance(sib, Tag) and sib.name == "h2"):
            if isinstance(sib, Tag):
                for strong in sib.find_all("strong"):
                    text = strong.get_text(strip=True)
                    if text and text not in meta.subsections:
                        meta.subsections.append(text)
            sib = sib.next_sibling

        sections.append(meta)

    return sections


def page_to_markdown(url: str, html: str) -> str:
    """
    Convert a docs HTML page to Markdown, preserving headings reasonably.
    """
    soup = BeautifulSoup(html, "html.parser")

    # Grab title from <h1> if present.
    body = soup.find("div", {"role": "main"}) or soup.body
    h1 = body.find("h1") if body else None
    title = h1.get_text(strip=True) if h1 else url

    sections = extract_sections(soup)

    # Convert the main content div to markdown.
    content_html = str(body) if body else html
    md_body = html_to_md(
        content_html,
        heading_style="ATX",
        strip=["script", "style", "nav", "footer"],
    )

    # Build a small YAML-style header with section metadata.
    lines: List[str] = []
    lines.append("---")
    lines.append(f"title: {title}")
    lines.append(f"source_url: {url}")
    if sections:
        lines.append("sections:")
        for sec in sections:
            lines.append(f"  - id: {sec.id}")
            lines.append(f"    title: {sec.title}")
            if sec.subsections:
                lines.append("    subsections:")
                for sub in sec.subsections:
                    lines.append(f"      - {sub}")
    else:
        lines.append("sections: []")
    lines.append("---")
    lines.append("")
    lines.append(md_body.strip())
    lines.append("")
    return "\n".join(lines)


def crawl_docs(
    base_url: str,
    output_root: Path,
    max_pages: Optional[int] = None,
    resume: bool = True,
) -> None:
    """
    Crawl Godot docs starting at base_url, save structured Markdown files under output_root.
    """
    session = requests.Session()
    seen: Set[str] = set()
    queue: deque[str] = deque()

    queue.append(base_url)
    seen.add(urldefrag(base_url)[0])

    while queue:
        url = queue.popleft()
        clean_url, _ = urldefrag(url)

        try:
            print(f"[scrape] GET {clean_url}")
            resp = session.get(clean_url, timeout=15)
            resp.raise_for_status()
        except Exception as exc:  # noqa: BLE001
            print(f"[scrape] ERROR fetching {clean_url}: {exc}", file=sys.stderr)
            continue

        html = resp.text
        soup = BeautifulSoup(html, "html.parser")

        # Write page markdown (or skip if already present when resuming).
        out_path = path_from_url(clean_url, base_url, output_root)
        if resume and out_path.exists():
            print(f"[scrape] SKIP (already exists): {out_path}")
        else:
            out_path.parent.mkdir(parents=True, exist_ok=True)
            md = page_to_markdown(clean_url, html)
            out_path.write_text(md, encoding="utf-8")

        # Enqueue child links.
        for a in soup.find_all("a", href=True):
            href = a["href"]
            full = urljoin(clean_url, href)
            full, _ = urldefrag(full)
            if not is_docs_url(full, base_url):
                continue
            if full in seen:
                continue
            seen.add(full)
            queue.append(full)

        if max_pages is not None and len(seen) >= max_pages:
            break


def main() -> None:
    parser = argparse.ArgumentParser(description="Scrape Godot 4.x docs into structured Markdown.")
    parser.add_argument(
        "--base-url",
        default=GODOT_BASE_URL,
        help="Root docs URL to crawl (default: stable branch).",
    )
    parser.add_argument(
        "--output-root",
        default=str(
            (Path(__file__).resolve().parent / ".." / ".." / ".." / "godot_knowledge_base" / "docs" / "4.6").resolve()
        ),
        help=(
            "Output root directory for Markdown files. "
            "Defaults to the repo-level godot_knowledge_base/docs/4.6 directory "
            "so it matches the docs indexer."
        ),
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=None,
        help="Optional limit on number of pages to crawl (for testing).",
    )
    parser.add_argument(
        "--no-resume",
        action="store_true",
        help="Disable resume behavior (always overwrite existing markdown files).",
    )

    args = parser.parse_args()
    base_url = args.base_url
    output_root = Path(args.output_root).resolve()

    print(f"[scrape] Base URL: {base_url}")
    print(f"[scrape] Output root: {output_root}")
    output_root.mkdir(parents=True, exist_ok=True)

    crawl_docs(
        base_url=base_url,
        output_root=output_root,
        max_pages=args.max_pages,
        resume=not args.no_resume,
    )


if __name__ == "__main__":
    main()

