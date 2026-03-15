"""
Code samples from repos: formatting full script implementations by extends_class
for the "component scripts" block (first to drop when context fills).
"""

from typing import Any, List

# Shown whenever we inject scraped/repo code so the LLM does not treat it as the user's project.
SCRAPED_CODE_DISCLAIMER = (
    "[IMPORTANT] The code below is from a wide range of different open-source Godot repos (scraped/indexed), "
    "not from the user's project. It may reference project-specific types, addons, or paths. "
    "Use it only as reference for structure and patterns; do not assume classes or paths exist in the user's project.\n"
)


def format_component_scripts_block(extends_class: str, scripts: List[Any]) -> str:
    """
    Format a list of full-script SourceChunks (extends_class) into one block of text.
    scripts: list of objects with .source_path, .text_preview, .metadata.
    """
    if not scripts:
        return ""
    lines = [
        SCRAPED_CODE_DISCLAIMER.strip(),
        "",
        f"=== Full script implementations (extends {extends_class}) ===",
        "Example scripts from indexed repos (various projects). Use as reference for structure and patterns only.",
        "",
    ]
    for s in scripts:
        path = getattr(s, "source_path", str(s))
        meta = getattr(s, "metadata", None) or {}
        importance = meta.get("importance", 0.0)
        lines.append(f"[FULL_SCRIPT] path={path} (extends {extends_class}, importance={importance})")
        lines.append("")
        lines.append(getattr(s, "text_preview", ""))
        lines.append("")
    return "\n".join(lines)
