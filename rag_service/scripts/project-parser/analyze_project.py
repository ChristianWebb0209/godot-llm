import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

import chromadb
from chromadb.utils import embedding_functions
from dotenv import load_dotenv

# Allow importing shared script_extends from scripts/common.
_SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from common.script_extends import is_native_godot_extends


@dataclass
class ScriptInfo:
    path: Path
    rel_path: str
    language: str = "gdscript"
    extends: Optional[str] = None
    loc: int = 0
    uses_signals: bool = False
    uses_input: bool = False
    uses_callbacks: bool = False
    uses_physics_move: bool = False
    reachable_from_main: bool = False
    referenced_by_scenes: Set[str] = field(default_factory=set)
    autoload: bool = False
    tags: List[str] = field(default_factory=list)
    role: Optional[str] = None
    importance: float = 0.0
    is_tool: bool = False  # @tool / [Tool] – editor-only, can down-weight in retrieval
    class_name: Optional[str] = None  # GDScript class_name or C# class name
    description: Optional[str] = None  # First comment block (top docstring), max ~200 chars for index


@dataclass
class SceneInfo:
    path: Path
    rel_path: str
    root_type: Optional[str] = None
    scripts: Set[str] = field(default_factory=set)  # rel script paths
    sub_scenes: Set[str] = field(default_factory=set)  # rel scene paths
    reachable_from_main: bool = False


def log(message: str) -> None:
    """
    Simple stdout logger for CLI feedback.
    """
    print(message)


# Default tag rules (used when tag_rules.json is missing).
_DEFAULT_EXTENDS_TAGS: Dict[str, List[str]] = {
    "CharacterBody2D": ["2d", "movement", "character"],
    "CharacterBody3D": ["3d", "movement", "character"],
    "Node2D": ["2d"],
    "Node3D": ["3d"],
    "Control": ["ui"],
}
_DEFAULT_PATH_KEYWORDS: Dict[str, List[str]] = {
    "player": ["player"], "hero": ["player"],
    "enemy": ["enemy", "ai"], "mob": ["enemy", "ai"],
    "ui": ["ui", "menu"], "menu": ["ui", "menu"], "hud": ["ui", "menu"], "pause": ["ui", "menu"],
    "level": ["level"], "world": ["level"], "map": ["level"],
    "main": ["main"], "game": ["main"],
}


def _load_tag_rules() -> Tuple[Dict[str, List[str]], Dict[str, List[str]]]:
    """Load extends and path_keywords from tag_rules.json; fall back to defaults."""
    rules_path = Path(__file__).resolve().parent / "tag_rules.json"
    if not rules_path.exists():
        return _DEFAULT_EXTENDS_TAGS.copy(), _DEFAULT_PATH_KEYWORDS.copy()
    try:
        data = json.loads(rules_path.read_text(encoding="utf-8"))
        extends = {k: list(v) for k, v in (data.get("extends") or {}).items()}
        path_kw = {k: list(v) for k, v in (data.get("path_keywords") or {}).items()}
        return extends or _DEFAULT_EXTENDS_TAGS.copy(), path_kw or _DEFAULT_PATH_KEYWORDS.copy()
    except (json.JSONDecodeError, OSError):
        return _DEFAULT_EXTENDS_TAGS.copy(), _DEFAULT_PATH_KEYWORDS.copy()


_MAX_DESCRIPTION_LEN = 200


def _extract_top_comment(lines: List[str], language: str) -> str:
    """
    Extract the first comment block for index/Chroma (description).
    Returns a single line or short paragraph, capped at _MAX_DESCRIPTION_LEN chars.
    """
    collected: List[str] = []
    if language == "gdscript":
        for ln in lines[:25]:
            s = ln.strip()
            if s.startswith("#"):
                part = s.lstrip("#").strip()
                if part:
                    collected.append(part)
            elif collected and s:
                break
    elif language == "csharp":
        in_block = False
        for ln in lines[:30]:
            s = ln.strip()
            if s.startswith("///"):
                collected.append(s.lstrip("/").strip())
            elif s.startswith("/*"):
                in_block = True
                content = s[2:].split("*/", 1)[0].strip()
                if content:
                    collected.append(content)
            elif in_block:
                if "*/" in s:
                    in_block = False
                    content = s.split("*/", 1)[0].strip()
                    if content:
                        collected.append(content)
                else:
                    collected.append(s)
            elif s.startswith("//") and not collected:
                collected.append(s.lstrip("/").strip())
            elif collected and s and not s.startswith("//"):
                break
    if not collected:
        return ""
    out = " ".join(collected).replace("\n", " ").strip()
    out = re.sub(r"\s+", " ", out)
    if len(out) > _MAX_DESCRIPTION_LEN:
        out = out[:_MAX_DESCRIPTION_LEN - 3].rsplit(" ", 1)[0] + "..."
    return out


def read_project_godot(project_root: Path) -> Tuple[Optional[str], Dict[str, str]]:
    """
    Very lightweight parser for project.godot.
    Returns (main_scene_rel_path, autoload_scripts_map).
    """
    cfg_path = project_root / "project.godot"
    if not cfg_path.exists():
        return None, {}

    main_scene: Optional[str] = None
    autoloads: Dict[str, str] = {}
    section = None
    for line in cfg_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line.strip("[]")
            continue
        if "=" not in line:
            continue
        key, value = [p.strip() for p in line.split("=", 1)]
        # Values are often in quotes, strip them.
        value = value.strip("\"'")
        if section == "application" and key == "run/main_scene":
            main_scene = value  # e.g. "res://main.tscn"
        elif section and section.startswith("autoload"):
            # autoload entries look like: MySingleton="*res://autoload/singleton.gd"
            script_path = value.lstrip("*")
            autoloads[key] = script_path
    return main_scene, autoloads


def parse_tscn(scene_path: Path, project_root: Path) -> SceneInfo:
    """
    Minimal TSCN parser to get:
    - root node type
    - scripts attached to nodes
    - instanced sub-scenes
    """
    rel_scene = scene_path.relative_to(project_root).as_posix()
    ext_resources: Dict[str, str] = {}  # id -> path
    root_type: Optional[str] = None
    scripts: Set[str] = set()
    sub_scenes: Set[str] = set()

    current_section = None
    is_root_node = True

    for raw in scene_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line.strip("[]")
            # Detect root node.
            if current_section.startswith("node "):
                # Root node is the first [node] without "parent=".
                is_root_node = "parent=" not in current_section
                if is_root_node:
                    m_type = re.search(r'type="([^"]+)"', current_section)
                    if m_type:
                        root_type = m_type.group(1)
                # Detect instanced sub-scenes.
                m_inst = re.search(r'instance=ExtResource\("(\d+)"\)', current_section)
                if m_inst:
                    res_id = m_inst.group(1)
                    res_path = ext_resources.get(res_id)
                    if res_path and res_path.endswith(".tscn"):
                        sub_scenes.add(res_path)
            continue

        if current_section and current_section.startswith("ext_resource"):
            # Example: [ext_resource type="Script" path="res://player/Player.gd" id="1"]
            m_id = re.search(r'id="([^"]+)"', current_section)
            m_path = re.search(r'path="([^"]+)"', current_section)
            if m_id and m_path:
                ext_resources[m_id.group(1)] = m_path.group(1)
            continue

        # Inside a node: look for script assignments.
        if current_section and current_section.startswith("node "):
            m_script = re.search(r'^script\s*=\s*ExtResource\("([^"]+)"\)', line)
            if m_script:
                res_id = m_script.group(1)
                script_path = ext_resources.get(res_id)
                if script_path and (script_path.endswith(".gd") or script_path.endswith(".cs")):
                    scripts.add(script_path)

    return SceneInfo(
        path=scene_path,
        rel_path=rel_scene,
        root_type=root_type,
        scripts=scripts,
        sub_scenes=sub_scenes,
        reachable_from_main=False,
    )


def analyze_script(script_path: Path, project_root: Path) -> ScriptInfo:
    rel = script_path.relative_to(project_root).as_posix()
    text = script_path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    loc = sum(1 for ln in lines if ln.strip())

    # Basic "extends" detection.
    extends: Optional[str] = None
    extends_re = re.compile(r'^\s*extends\s+([A-Za-z0-9_".]+)')
    for ln in lines[:20]:
        m = extends_re.match(ln)
        if m:
            extends = m.group(1).strip('"')
            break

    # @tool and class_name (first 30 lines).
    is_tool = any(re.search(r'^\s*@tool\b', ln) for ln in lines[:30])
    class_name_val: Optional[str] = None
    class_name_re = re.compile(r'^\s*class_name\s+([A-Za-z0-9_]+)')
    for ln in lines[:30]:
        m = class_name_re.match(ln)
        if m:
            class_name_val = m.group(1)
            break

    uses_signals = any("signal " in ln or ".connect(" in ln or "emit_signal" in ln for ln in lines)
    uses_input = any("Input." in ln or "InputMap" in ln for ln in lines)
    uses_callbacks = any(
        re.search(r'\b(_ready|_process|_physics_process|_input)\b', ln) for ln in lines
    )
    uses_physics_move = any(
        "move_and_slide" in ln or "move_and_collide" in ln for ln in lines
    )
    description = _extract_top_comment(lines, "gdscript") or None

    return ScriptInfo(
        path=script_path,
        rel_path=rel,
        language="gdscript",
        extends=extends,
        loc=loc,
        uses_signals=uses_signals,
        uses_input=uses_input,
        uses_callbacks=uses_callbacks,
        uses_physics_move=uses_physics_move,
        is_tool=is_tool,
        class_name=class_name_val,
        description=description,
    )


# Known Godot C# base types (engine nodes/resources). Used to treat a .cs file as a
# Godot script and to avoid indexing non-Godot C# (e.g. tooling) as "Node".
# Normalized names only (no "Godot." prefix). Add engine types as needed.
GODOT_CSHARP_BASE_TYPES: Set[str] = {
    "Node", "Node2D", "Node3D", "Control", "CharacterBody2D", "CharacterBody3D",
    "RigidBody2D", "RigidBody3D", "StaticBody2D", "StaticBody3D",
    "Area2D", "Area3D", "Camera2D", "Camera3D", "Sprite2D", "Sprite3D",
    "MeshInstance2D", "MeshInstance3D", "CollisionShape2D", "CollisionShape3D",
    "AnimationPlayer", "AnimationTree", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D",
    "Resource", "RefCounted", "Object", "GodotObject",
    "PhysicsBody2D", "PhysicsBody3D", "CollisionObject2D", "CollisionObject3D",
    "CanvasItem", "Viewport", "Window", "SubViewport",
    "Shader", "ShaderMaterial", "Material", "BaseMaterial3D",
    "Variant", "StringName", "NodePath",
}


def _normalize_csharp_extends(base: str) -> str:
    """Strip Godot. prefix so extends_class matches GDScript and docs (e.g. CharacterBody2D)."""
    if not base:
        return ""
    s = base.strip()
    if s.startswith("Godot."):
        return s[6:].strip()
    return s


def analyze_csharp_script(script_path: Path, project_root: Path) -> ScriptInfo:
    """
    Lightweight analyzer for Godot C# scripts.
    - Extracts base class from `class Name : BaseType` or `class Name : Godot.BaseType`.
    - Normalizes to engine name (strips Godot. prefix).
    - If base is not a known Godot type, sets extends=None so the script is not
      indexed as a Godot component (avoids polluting project_code with tooling/non-Godot C#).
    """
    rel = script_path.relative_to(project_root).as_posix()
    text = script_path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    loc = sum(1 for ln in lines if ln.strip())

    # Detect base class from `class Name : BaseType`.
    extends: Optional[str] = None
    class_re = re.compile(
        r'^\s*(?:public\s+|internal\s+|partial\s+)*class\s+[A-Za-z0-9_]+\s*:\s*([A-Za-z0-9_\.]+)'
    )
    for ln in lines[:50]:
        m = class_re.match(ln)
        if m:
            raw_base = m.group(1)
            normalized = _normalize_csharp_extends(raw_base)
            # Only treat as Godot script if base is a known engine type.
            if normalized in GODOT_CSHARP_BASE_TYPES:
                extends = normalized
            break

    uses_signals = any(
        "Signal" in ln or "Connect(" in ln or "EmitSignal" in ln or "EmitSignal(" in ln
        for ln in lines
    )
    uses_input = any("Input." in ln or "InputMap" in ln for ln in lines)
    uses_callbacks = any(
        re.search(r'\b(_Ready|_Process|_PhysicsProcess|_Input)\s*\(', ln) for ln in lines
    )
    uses_physics_move = any(
        "MoveAndSlide" in ln or "MoveAndCollide" in ln for ln in lines
    )

    # [Tool] and class name from declaration.
    is_tool = any(re.search(r'^\s*\[Tool\]', ln) for ln in lines[:30])
    class_name_val: Optional[str] = None
    class_match = re.search(
        r'^\s*(?:public\s+|internal\s+|partial\s+)*class\s+([A-Za-z0-9_]+)',
        "\n".join(lines[:50]),
        re.MULTILINE,
    )
    if class_match:
        class_name_val = class_match.group(1)
    description = _extract_top_comment(lines, "csharp") or None

    return ScriptInfo(
        path=script_path,
        rel_path=rel,
        language="csharp",
        extends=extends,
        loc=loc,
        uses_signals=uses_signals,
        uses_input=uses_input,
        uses_callbacks=uses_callbacks,
        uses_physics_move=uses_physics_move,
        is_tool=is_tool,
        class_name=class_name_val,
        description=description,
    )


def analyze_gdshader(script_path: Path, project_root: Path) -> ScriptInfo:
    """
    Lightweight analyzer for Godot .gdshader files.
    We currently treat shaders similarly to scripts for ingestion purposes:
    - Capture relative path and LOC.
    - Mark language as 'gdshader'.
    - Leave extends/flags empty so importance is driven mainly by size and path hints.
    """
    rel = script_path.relative_to(project_root).as_posix()
    text = script_path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    loc = sum(1 for ln in lines if ln.strip())

    return ScriptInfo(
        path=script_path,
        rel_path=rel,
        language="gdshader",
        extends=None,
        loc=loc,
        uses_signals=False,
        uses_input=False,
        uses_callbacks=False,
        uses_physics_move=False,
    )


def _infer_shader_tags(script_path: Path) -> List[str]:
    """Infer tags from .gdshader render_mode (canvas_item, spatial, particles)."""
    tags: List[str] = ["shader"]
    try:
        text = script_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return tags
    # render_mode unquote_render_mode canvas_item | spatial | particles | sky | ...
    for line in text.splitlines()[:40]:
        line = line.strip()
        if "render_mode" in line:
            if "canvas_item" in line:
                tags.append("canvas_item")
            if "spatial" in line:
                tags.append("spatial")
            if "particles" in line:
                tags.append("particles")
            if "sky" in line:
                tags.append("sky")
            break
    return tags


def infer_tags_and_role(info: ScriptInfo) -> None:
    extends_rules, path_keywords = _load_tag_rules()
    tags: Set[str] = set()

    # Config-driven: extends -> tags (match any rule key that appears in extends).
    if info.extends:
        for key, tag_list in extends_rules.items():
            if key in info.extends:
                tags.update(tag_list)

    # Config-driven: path keywords.
    lower_path = info.rel_path.lower()
    for keyword, tag_list in path_keywords.items():
        if keyword in lower_path:
            tags.update(tag_list)

    # Shader: infer from render_mode (read file).
    if info.language == "gdshader":
        tags.update(_infer_shader_tags(info.path))
        info.tags = sorted(tags)
        info.role = None
        return

    # API usage tags.
    if info.uses_input:
        tags.add("input")
    if info.uses_signals:
        tags.add("signals")
    if info.uses_physics_move:
        tags.update(["physics", "movement"])

    # Editor/tool scripts: down-weight or filter in retrieval.
    if info.is_tool:
        tags.add("editor")

    info.tags = sorted(tags)

    # Role: single component_type for Chroma filter; expand heuristics as needed.
    role: Optional[str] = None
    if "2d" in tags and "movement" in tags and "character" in tags and "player" in tags:
        role = "2d_player_controller"
    elif "ui" in tags and "menu" in tags and "pause" in lower_path:
        role = "pause_menu_ui"
    elif "enemy" in tags and "ai" in tags and "2d" in tags:
        role = "basic_enemy_ai"
    elif "editor" in tags:
        role = "editor_plugin"
    info.role = role


def compute_importance(info: ScriptInfo) -> float:
    """
    Rough importance score in [0,1] based on:
    - reachability from main / autoload
    - number of referencing scenes
    - API usage richness
    - path/name hints
    - size bounds
    """
    score = 0.0

    # 1. Main graph / autoload.
    if info.reachable_from_main:
        score += 0.4
    if info.autoload:
        score += 0.3

    # 2. Referenced by scenes.
    ref_count = len(info.referenced_by_scenes)
    if ref_count > 0:
        score += min(0.2, 0.05 * ref_count)  # cap at 4 scenes

    # 3. Godot API richness.
    api_score = 0.0
    if info.uses_signals:
        api_score += 0.2
    if info.uses_input:
        api_score += 0.1
    if info.uses_callbacks:
        api_score += 0.1
    if info.uses_physics_move:
        api_score += 0.1
    score += min(0.3, api_score)

    # 4. Path/name hints.
    name_score = 0.0
    lower_path = info.rel_path.lower()
    if "player" in lower_path:
        name_score += 0.15
    if "enemy" in lower_path or "ai" in lower_path:
        name_score += 0.1
    if "menu" in lower_path or "hud" in lower_path:
        name_score += 0.1
    if "main" in lower_path or "game" in lower_path:
        name_score += 0.1
    score += min(0.2, name_score)

    # 5. Size bounds.
    if info.loc <= 5:
        size_score = 0.0
    elif info.loc <= 400:
        size_score = 0.1
    elif info.loc <= 800:
        size_score = 0.05
    else:
        size_score = 0.0
    score += size_score

    return max(0.0, min(1.0, score))


def build_scene_graph(
    scenes: Dict[str, SceneInfo],
    main_scene_res: Optional[str],
    project_root: Path,
) -> None:
    """
    Mark reachable scenes/scripts starting from the main scene.
    """
    if not main_scene_res:
        return

    # main_scene_res is like "res://main.tscn"
    if not main_scene_res.startswith("res://"):
        return
    main_rel = main_scene_res.replace("res://", "")
    main_rel = main_rel.lstrip("/")
    queue: List[str] = []
    for rel, info in scenes.items():
        if rel == main_rel:
            info.reachable_from_main = True
            queue.append(rel)
            break

    while queue:
        current = queue.pop(0)
        cur_scene = scenes.get(current)
        if not cur_scene:
            continue
        for sub in cur_scene.sub_scenes:
            sub_rel = sub.replace("res://", "").lstrip("/")
            sub_info = scenes.get(sub_rel)
            if sub_info and not sub_info.reachable_from_main:
                sub_info.reachable_from_main = True
                queue.append(sub_rel)


def _safe_extends_dir(extends: str) -> str:
    """Folder-safe name for extends class (e.g. CharacterBody2D -> CharacterBody2D)."""
    return re.sub(r'[\\/:*?"<>|\s]+', "_", (extends or "").strip()).strip("_") or "Node"


# Directories under scraped_repos we skip when scanning component folders.
_SCRAPED_SKIP_DIRS = frozenset({"_repos", "index"})

# Max entries per index file so they stay usable in context (~few hundred).
MAX_ENTRIES_PER_INDEX = 400


def _safe_index_suffix(s: str) -> str:
    """Safe filename suffix (alnum + underscore)."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", (s or "").strip()).strip("_") or "general"


# Path keywords used to sub-split "general" into meaningful buckets for context.
_PATH_SEMANTIC_KEYWORDS: List[Tuple[str, str]] = [
    ("player", "player"), ("hero", "player"),
    ("enemy", "enemy"), ("mob", "enemy"), ("ai", "enemy"),
    ("menu", "ui"), ("ui", "ui"), ("hud", "ui"), ("pause", "ui"),
    ("editor", "editor"),
    ("main", "main"), ("game", "main"),
    ("level", "level"), ("world", "level"), ("map", "level"),
]


def _semantic_group_key(entry: Dict) -> str:
    """
    Meaningful group key for context: role > first tag > general.
    Used so we know what to load into context (e.g. 'pause_menu_ui', 'ui', 'signals').
    """
    role = (entry.get("role") or "").strip()
    if role:
        return role
    tags = entry.get("tags") or []
    if tags:
        return tags[0]
    return "general"


def _path_semantic_bucket(rel_path: str) -> str:
    """
    Bucket from path for sub-splitting large groups (player, enemy, ui, editor, main, level, misc).
    So we get meaningful chunks like index_main_player.json, index_general_ui.json.
    """
    lower = rel_path.lower()
    for _keyword, bucket in _PATH_SEMANTIC_KEYWORDS:
        if _keyword in lower:
            return bucket
    return "misc"


def analyze_scraped_root(
    scraped_root: Path,
    importance_threshold: float,
    dry_run: bool,
) -> None:
    """
    Scan the scraped_repos component layout: recurse each component folder (Node2D,
    Camera3D, etc.), analyze every script/shader, and write index file(s) per component.
    No project.godot; extends come from the folder name. Large components are split by
    meaning: role (e.g. 2d_player_controller) or first tag (ui, signals, main), then by
    path semantics (player, enemy, ui, editor, level, misc) if still > MAX. No master index.
    """
    scraped_root = scraped_root.resolve()
    if not scraped_root.is_dir():
        log(f"[scraped] Root does not exist or is not a directory: {scraped_root}")
        return

    KEEP_EXTENSIONS = (".gd", ".cs", ".gdshader")
    # Component name = first path segment under scraped_root (e.g. Node2D, Other).
    component_scripts: Dict[str, List[ScriptInfo]] = {}

    for comp_dir in sorted(scraped_root.iterdir()):
        if not comp_dir.is_dir() or comp_dir.name in _SCRAPED_SKIP_DIRS:
            continue
        component_name = comp_dir.name
        component_scripts[component_name] = []
        for path in comp_dir.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in KEEP_EXTENSIONS:
                continue
            try:
                rel = path.relative_to(scraped_root).as_posix()
            except ValueError:
                continue
            if path.suffix.lower() == ".gd":
                info = analyze_script(path, scraped_root)
            elif path.suffix.lower() == ".cs":
                info = analyze_csharp_script(path, scraped_root)
            else:
                info = analyze_gdshader(path, scraped_root)
            info.extends = component_name
            component_scripts[component_name].append(info)

    total = sum(len(v) for v in component_scripts.values())
    log(f"[scraped] Found {total} scripts in {len(component_scripts)} component(s): {sorted(component_scripts.keys())}")

    for info in (i for infos in component_scripts.values() for i in infos):
        infer_tags_and_role(info)
        info.importance = compute_importance(info)

    all_meta: Dict[str, Dict] = {}
    for component_name, infos in component_scripts.items():
        entries: List[Dict] = []
        for info in infos:
            component_type = (info.role or "").strip() or (info.tags[0] if info.tags else "general")
            entry: Dict = {
                "path": info.rel_path,
                "project_id": "scraped",
                "rel_path": info.rel_path,
                "extends_class": component_name,
                "component_type": component_type,
                "role": info.role,
                "language": info.language,
                "tags": info.tags or [],
                "importance": float(info.importance),
            }
            if info.class_name:
                entry["class_name"] = info.class_name
            if info.description:
                desc = (info.description or "").strip()
                if len(desc) > _MAX_DESCRIPTION_LEN:
                    desc = desc[:_MAX_DESCRIPTION_LEN]
                entry["description"] = desc
            entries.append(entry)
            info_dict = asdict(info)
            info_dict["path"] = info.rel_path
            info_dict["component_type"] = component_type
            for key, value in list(info_dict.items()):
                if isinstance(value, set):
                    info_dict[key] = sorted(value)
            all_meta[info.rel_path] = info_dict
            if isinstance(info_dict.get("path"), Path):
                info_dict["path"] = str(info_dict["path"])

        if dry_run:
            if len(entries) <= MAX_ENTRIES_PER_INDEX:
                log(f"[scraped] Would write {component_name}/index.json ({len(entries)} entries)")
            else:
                log(f"[scraped] Would write {component_name}/index_*.json (split from {len(entries)} entries)")
            continue

        comp_dir_path = scraped_root / component_name
        comp_dir_path.mkdir(parents=True, exist_ok=True)

        if len(entries) <= MAX_ENTRIES_PER_INDEX:
            (comp_dir_path / "index.json").write_text(json.dumps(entries, indent=2), encoding="utf-8")
            log(f"[scraped] Wrote {component_name}/index.json ({len(entries)} entries)")
        else:
            # Group by meaning: role > first tag > general (so we know what to put in context).
            by_semantic: Dict[str, List[Dict]] = {}
            for e in entries:
                key = _semantic_group_key(e)
                by_semantic.setdefault(key, []).append(e)
            written = 0
            for sem_key, group in sorted(by_semantic.items()):
                if len(group) <= MAX_ENTRIES_PER_INDEX:
                    name = f"index_{_safe_index_suffix(sem_key)}.json"
                    (comp_dir_path / name).write_text(json.dumps(group, indent=2), encoding="utf-8")
                    log(f"[scraped] Wrote {component_name}/{name} ({len(group)} entries)")
                    written += 1
                else:
                    # Sub-split by path meaning (player, enemy, ui, editor, main, level, misc).
                    by_path: Dict[str, List[Dict]] = {}
                    for e in group:
                        bucket = _path_semantic_bucket(e.get("rel_path", ""))
                        sub_key = f"{sem_key}_{bucket}"
                        by_path.setdefault(sub_key, []).append(e)
                    for sub_key, sub in sorted(by_path.items()):
                        name = f"index_{_safe_index_suffix(sub_key)}.json"
                        (comp_dir_path / name).write_text(json.dumps(sub, indent=2), encoding="utf-8")
                        log(f"[scraped] Wrote {component_name}/{name} ({len(sub)} entries)")
                        written += 1
            log(f"[scraped] {component_name}: {written} index file(s) from {len(entries)} entries")

    if not dry_run and all_meta:
        index_in_chromadb(project_slug="scraped", source_root=scraped_root, selected_meta=all_meta)


def copy_important_scripts(
    scripts: Dict[str, ScriptInfo],
    output_root: Path,
    importance_threshold: float,
    dry_run: bool,
    project_slug: Optional[str] = None,
    scraped_output: bool = False,
) -> Dict[str, Dict]:
    """
    Copy scripts with importance >= threshold to output_root.
    - Normal mode: output_root / project_slug / rel (preserves relative paths).
    - Scraped mode: output_root / <ExtendsClass> / project_slug__path__file.ext (skips Other/non-native).
    Returns metadata dict keyed by rel_path (or by new path in scraped mode).
    """
    meta: Dict[str, Dict] = {}
    for rel, info in scripts.items():
        if info.importance < importance_threshold:
            continue
        extends = (info.extends or "").strip() or "Node"
        if scraped_output:
            if not project_slug:
                continue
            if not is_native_godot_extends(extends):
                continue  # Skip Other / non-native; do not write to scraped_repos/Other
            safe_extends = _safe_extends_dir(extends)
            unique_name = f"{project_slug}__{rel.replace('/', '__')}"
            dst = output_root / safe_extends / unique_name
        else:
            dst = output_root / rel
        if not dry_run:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(info.path, dst)
        # Persist ScriptInfo to metadata; path is either rel or (scraped) extends_class/unique_name.
        info_dict = asdict(info)
        out_path = f"{_safe_extends_dir(extends)}/{project_slug}__{rel.replace('/', '__')}" if scraped_output else rel
        info_dict["path"] = out_path
        component_type = (info.role or "").strip() or (info.tags[0] if info.tags else "general")
        info_dict["component_type"] = component_type
        if isinstance(info_dict.get("path"), Path):
            info_dict["path"] = str(info_dict["path"])
        for key, value in list(info_dict.items()):
            if isinstance(value, set):
                info_dict[key] = sorted(value)
        meta[rel] = info_dict
    return meta


def index_in_chromadb(
    project_slug: str,
    source_root: Path,
    selected_meta: Dict[str, Dict],
) -> None:
    """
    Index selected scripts/shaders into a local ChromaDB collection instead of
    relying solely on JSON files.

    Each document is:
      - id: f"{project_slug}:{rel_path}"
      - document: full script/shader text
      - metadata: project_id, path, language, tags, importance
    """
    if not selected_meta:
        log("[chroma] No scripts to index; skipping ChromaDB.")
        return

    # Ensure .env is loaded so OPENAI_ env vars are visible here as well.
    load_dotenv()

    db_root = (Path(__file__).parent / ".." / ".." / ".." / "data" / "chroma_db").resolve()
    db_root.mkdir(parents=True, exist_ok=True)

    client = chromadb.PersistentClient(path=str(db_root))

    # Embeddings: only use OpenAI if key is set AND you didn't opt out (saves API credits).
    # With no key, or USE_LOCAL_EMBEDDINGS=1, Chroma uses local all-MiniLM-L6-v2 (free).
    use_local = os.getenv("USE_LOCAL_EMBEDDINGS", "").strip().lower() in ("1", "true", "yes")
    openai_api_key = os.getenv("OPENAI_API_KEY")
    openai_base_url = os.getenv("OPENAI_BASE_URL")
    embedding_fn = None
    if openai_api_key and not use_local:
        embedding_fn = embedding_functions.OpenAIEmbeddingFunction(
            api_key=openai_api_key,
            model_name=os.getenv("OPENAI_EMBED_MODEL", "text-embedding-3-small"),
            api_base=openai_base_url or None,
        )
        log("[chroma] Using OpenAI embeddings for project_code (uses API credits). Set USE_LOCAL_EMBEDDINGS=1 to use free local embeddings.")
    else:
        if use_local:
            log("[chroma] USE_LOCAL_EMBEDDINGS=1; using local embeddings for project_code (no API cost).")
        else:
            log("[chroma] No OPENAI_API_KEY; using local embeddings for project_code (no API cost).")

    # Rebuild from scratch so we always use the intended embedding (no stale default).
    try:
        client.delete_collection("project_code")
        log("[chroma] Deleted existing project_code collection; rebuilding.")
    except Exception:
        pass  # Collection did not exist
    collection = client.create_collection("project_code", embedding_function=embedding_fn)

    ids: List[str] = []
    documents: List[str] = []
    metadatas: List[Dict[str, object]] = []

    for rel, info in selected_meta.items():
        rel_path = Path(rel)
        script_path = source_root / rel_path
        try:
            text = script_path.read_text(encoding="utf-8", errors="ignore")
        except FileNotFoundError:
            log(f"[chroma] Skipping missing file for indexing: {script_path}")
            continue

        extends_class = (info.get("extends") or "").strip()
        # Skip non-Godot C# (e.g. tooling): they have extends=None and would pollute "Node".
        if info.get("language") == "csharp" and not extends_class:
            continue

        tags = info.get("tags") or []
        component_type = (info.get("component_type") or "").strip() or "general"
        class_name = (info.get("class_name") or "").strip()
        description = (info.get("description") or "").strip()
        if len(description) > _MAX_DESCRIPTION_LEN:
            description = description[:_MAX_DESCRIPTION_LEN]
        # One-line prefix so embeddings see extends/class/summary; minimal space.
        prefix_parts = [f"extends {extends_class or 'Node'}"]
        if class_name:
            prefix_parts.append(f"class {class_name}")
        if description:
            prefix_parts.append(description)
        doc_prefix = "# " + " | ".join(prefix_parts) + "\n\n"
        document_text = doc_prefix + text
        # OpenAI embedding models (e.g. text-embedding-3-small) have an 8192-token limit per input.
        # Truncate by chars to stay under (~4 chars/token for code).
        _MAX_EMBED_CHARS = 30_000  # ~7500 tokens
        if len(document_text) > _MAX_EMBED_CHARS:
            document_text = document_text[:_MAX_EMBED_CHARS] + "\n# ... (truncated for embedding)"

        ids.append(f"{project_slug}:{rel}")
        documents.append(document_text)
        stored_path = info.get("path", rel)
        if isinstance(stored_path, Path):
            stored_path = str(stored_path)
        md: Dict[str, object] = {
            "project_id": project_slug,
            "path": stored_path,
            "language": info.get("language", ""),
            "importance": info.get("importance", 0.0),
            "extends_class": extends_class if extends_class else "Node",
            "component_type": component_type,
        }
        if tags:
            md["tags"] = tags
        role = (info.get("role") or "").strip()
        if role:
            md["role"] = role
        if class_name:
            md["class_name"] = class_name
        if description:
            md["description"] = description
        metadatas.append(md)

    if not ids:
        log("[chroma] No valid documents collected for ChromaDB; nothing to add.")
        return

    # Add in batches to avoid huge single requests; each document is already truncated to fit embedding model limit.
    BATCH_SIZE = 200
    total = len(ids)
    log(f"[chroma] Indexing {total} documents into ChromaDB at {db_root}...")
    for start in range(0, total, BATCH_SIZE):
        end = min(start + BATCH_SIZE, total)
        batch_ids = ids[start:end]
        batch_docs = documents[start:end]
        batch_meta = metadatas[start:end]
        collection.add(ids=batch_ids, documents=batch_docs, metadatas=batch_meta)
        log(f"[chroma] Indexed {end}/{total} documents.")
    log("[chroma] Indexing complete.")


def write_index_files(
    project_slug: str,
    output_root: Path,
    selected_meta: Dict[str, Dict],
    scraped_output: bool = False,
) -> None:
    """
    Write master index (all scripts with tags, extends, importance) and per-component
    index files. Enables: one master index.json for the whole codebase, plus
    by_extends/<ExtendsClass>.json listing scripts that extend that class from any repo.
    When scraped_output=True, index lives under output_root/index (not output_root.parent/index),
    and entries use the component-relative path; by_extends skips "Other".
    """
    if not selected_meta:
        return

    if scraped_output:
        index_root = output_root / "index"
    else:
        index_root = output_root.parent / "index"
    index_root.mkdir(parents=True, exist_ok=True)
    by_extends_dir = index_root / "by_extends"
    by_extends_dir.mkdir(parents=True, exist_ok=True)

    # Build entries for this project.
    entries: List[Dict] = []
    for rel, info in selected_meta.items():
        extends_class = (info.get("extends") or "").strip() or "Node"
        component_type = (info.get("component_type") or "").strip() or "general"
        # In scraped mode path is already extends_class/unique_name; otherwise project_slug/rel.
        path_val = info.get("path", rel)
        if isinstance(path_val, Path):
            path_val = str(path_val)
        if not scraped_output:
            path_val = f"{project_slug}/{rel}"
        entry: Dict = {
            "path": path_val,
            "project_id": project_slug,
            "rel_path": rel,
            "extends_class": extends_class,
            "component_type": component_type,
            "role": info.get("role"),
            "language": info.get("language", ""),
            "tags": info.get("tags") or [],
            "importance": float(info.get("importance", 0.0)),
        }
        if info.get("class_name"):
            entry["class_name"] = info.get("class_name")
        if info.get("description"):
            desc = (info.get("description") or "").strip()
            if len(desc) > _MAX_DESCRIPTION_LEN:
                desc = desc[:_MAX_DESCRIPTION_LEN]
            entry["description"] = desc
        entries.append(entry)

    # Master index: merge with existing (replace entries for this project_slug, then add new).
    master_path = index_root / "master.json"
    existing_master: List[Dict] = []
    if master_path.exists():
        try:
            existing_master = json.loads(master_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            existing_master = []
    existing_master = [e for e in existing_master if e.get("project_id") != project_slug]
    existing_master.extend(entries)
    master_path.write_text(json.dumps(existing_master, indent=2), encoding="utf-8")
    log(f"[index] Wrote master index ({len(existing_master)} total entries) to {master_path}")

    # Per-component: for each extends_class touched, merge into that file. Skip Other in scraped mode.
    extends_seen: Set[str] = set()
    for e in entries:
        if scraped_output and (e["extends_class"] == "Other" or not is_native_godot_extends(e["extends_class"])):
            continue
        extends_seen.add(e["extends_class"])

    for extends_class in extends_seen:
        safe_name = _safe_extends_dir(extends_class)
        comp_path = by_extends_dir / f"{safe_name}.json"
        existing_comp: List[Dict] = []
        if comp_path.exists():
            try:
                existing_comp = json.loads(comp_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                existing_comp = []
        existing_comp = [e for e in existing_comp if e.get("project_id") != project_slug]
        new_for_comp = [e for e in entries if e["extends_class"] == extends_class]
        existing_comp.extend(new_for_comp)
        comp_path.write_text(json.dumps(existing_comp, indent=2), encoding="utf-8")
    log(f"[index] Wrote by_extends indexes for {len(extends_seen)} component(s)")


def analyze_project(
    source_root: Path,
    output_root: Path,
    importance_threshold: float,
    slug: Optional[str],
    dry_run: bool,
    scraped_output: bool = False,
) -> None:
    log(f"[analyze_project] Source root: {source_root}")
    if not (source_root / "project.godot").exists():
        raise RuntimeError(f"No project.godot found under {source_root}")

    main_scene_res, autoloads = read_project_godot(source_root)

    # Discover scenes and scripts.
    scenes: Dict[str, SceneInfo] = {}
    scripts: Dict[str, ScriptInfo] = {}

    log("[analyze_project] Scanning scenes (*.tscn)...")
    for path in source_root.rglob("*.tscn"):
        info = parse_tscn(path, source_root)
        scenes[info.rel_path] = info

    log("[analyze_project] Scanning GDScript (*.gd)...")
    for path in source_root.rglob("*.gd"):
        info = analyze_script(path, source_root)
        scripts[info.rel_path] = info

    log("[analyze_project] Scanning C# (*.cs)...")
    for path in source_root.rglob("*.cs"):
        info = analyze_csharp_script(path, source_root)
        scripts[info.rel_path] = info

    log("[analyze_project] Scanning shaders (*.gdshader)...")
    for path in source_root.rglob("*.gdshader"):
        info = analyze_gdshader(path, source_root)
        scripts[info.rel_path] = info

    log(
        f"[analyze_project] Discovered {len(scenes)} scenes, "
        f"{len([s for s in scripts.values() if s.language == 'gdscript'])} GDScript, "
        f"{len([s for s in scripts.values() if s.language == 'csharp'])} C#, "
        f"{len([s for s in scripts.values() if s.language == 'gdshader'])} shaders."
    )

    # Mark autoload scripts.
    for _name, script_path in autoloads.items():
        rel = script_path.replace("res://", "").lstrip("/")
        if rel in scripts:
            scripts[rel].autoload = True

    # Build scene graph, mark reachable scenes.
    build_scene_graph(scenes, main_scene_res, source_root)

    # Wire scenes -> scripts and mark script reachability.
    for scene_rel, scene_info in scenes.items():
        if not scene_info.reachable_from_main:
            continue
        for script_res in scene_info.scripts:
            rel = script_res.replace("res://", "").lstrip("/")
            script_info = scripts.get(rel)
            if script_info:
                script_info.reachable_from_main = True
                script_info.referenced_by_scenes.add(scene_rel)

    # Infer tags, roles and compute importance.
    for info in scripts.values():
        infer_tags_and_role(info)
        info.importance = compute_importance(info)

    # Determine project slug.
    project_slug = slug or source_root.name
    project_output_root = output_root / project_slug
    log(f"[analyze_project] Project slug: {project_slug}")
    if scraped_output:
        log(f"[analyze_project] Output: scraped component folders under {output_root} (excluding Other)")
    else:
        log(f"[analyze_project] Output root: {project_output_root}")

    # Copy only important scripts (per-component when scraped_output).
    meta = copy_important_scripts(
        scripts=scripts,
        output_root=output_root if scraped_output else project_output_root,
        importance_threshold=importance_threshold,
        dry_run=dry_run,
        project_slug=project_slug if scraped_output else None,
        scraped_output=scraped_output,
    )
    log(
        f"[analyze_project] Selected {len(meta)} scripts/shaders with "
        f"importance >= {importance_threshold}."
    )

    # Index selected scripts in ChromaDB instead of relying on JSON metadata only.
    if not dry_run:
        index_in_chromadb(
            project_slug=project_slug,
            source_root=source_root,
            selected_meta=meta,
        )
        write_index_files(
            project_slug=project_slug,
            output_root=output_root,
            selected_meta=meta,
            scraped_output=scraped_output,
        )

    # Write a minimal PROJECT.md summary for humans/LLMs (only in non-scraped mode).
    if not dry_run and not scraped_output:
        project_output_root.mkdir(parents=True, exist_ok=True)

        components_lines: List[str] = [
            "---",
            f"project_id: {project_slug}",
            "components:",
        ]
        for rel, info in scripts.items():
            if info.importance < importance_threshold:
                continue
            components_lines.append(f"  - path: res://{rel}")
            components_lines.append(f"    language: {info.language}")
            if info.tags:
                tags_str = ", ".join(info.tags)
                components_lines.append(f"    tags: [{tags_str}]")
            components_lines.append(f"    importance: {info.importance:.3f}")
        components_lines.append("---")
        components_lines.append("")
        components_lines.append(
            f"Auto-generated manifest for project `{project_slug}`. "
            f"Only scripts with importance >= {importance_threshold} are listed."
        )
        (project_output_root / "PROJECT.md").write_text(
            "\n".join(components_lines),
            encoding="utf-8",
        )


def main() -> None:
    _base = Path(__file__).resolve().parent / ".." / ".." / ".."
    default_scraped_root = (_base / "godot_knowledge_base" / "scraped_repos").resolve()

    parser = argparse.ArgumentParser(
        description=(
            "Analyze the scraped_repos component layout: recurse each component folder, "
            "build index file(s) per component (split if >400 entries), and optionally ChromaDB."
        ),
        epilog=(
            "DEFAULT: Scans godot_knowledge_base/scraped_repos (no CLI needed).\n"
            "  - Skips _repos and index. Writes <Component>/index.json or index_<type>.json (split for Node/Other).\n"
            "OPTIONAL: --source-root for a single Godot project (project.godot) instead.\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--source-root",
        type=str,
        help="If set, analyze a single Godot project (must contain project.godot) instead of scraped_repos.",
    )
    parser.add_argument(
        "--scraped-root",
        type=str,
        default=str(default_scraped_root),
        help=f"Root of component folders (default: {default_scraped_root}).",
    )
    parser.add_argument(
        "--output-root",
        type=str,
        help="For single-project mode only: where to copy scripts and write index.",
    )
    parser.add_argument(
        "--importance-threshold",
        type=float,
        default=0.3,
        help="Used for single-project mode; scraped mode indexes all scripts.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Analyze and log but do not write any files.",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Before running: delete scraped_repos/index (scraped mode) or --output-root (single-project).",
    )

    args = parser.parse_args()
    importance_threshold = args.importance_threshold

    if args.source_root:
        # Single Godot project mode (legacy).
        source_root = Path(args.source_root).resolve()
        output_root = Path(args.output_root).resolve() if args.output_root else (default_scraped_root.parent / "code" / "demos").resolve()
        if args.clean and output_root.exists():
            log(f"[main] Cleaning output root: {output_root}")
            for child in output_root.iterdir():
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        if not (source_root / "project.godot").exists():
            log(f"[main] No project.godot under {source_root}; exiting.")
            return 1
        analyze_project(
            source_root=source_root,
            output_root=output_root,
            importance_threshold=importance_threshold,
            slug=None,
            dry_run=args.dry_run,
            scraped_output=False,
        )
        log("[main] Analysis completed successfully.")
        return 0

    # Default: scraped component layout.
    scraped_root = Path(args.scraped_root).resolve()
    if args.clean:
        index_dir = scraped_root / "index"
        if index_dir.exists():
            log(f"[main] Cleaning index: {index_dir}")
            shutil.rmtree(index_dir)
    log(f"[main] Scanning component folders under {scraped_root}")
    analyze_scraped_root(
        scraped_root=scraped_root,
        importance_threshold=importance_threshold,
        dry_run=args.dry_run,
    )
    log("[main] Analysis completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

