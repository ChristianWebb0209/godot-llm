import argparse
import json
import os
import re
import shutil
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

import chromadb
from chromadb.utils import embedding_functions
from dotenv import load_dotenv


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

    uses_signals = any("signal " in ln or ".connect(" in ln or "emit_signal" in ln for ln in lines)
    uses_input = any("Input." in ln or "InputMap" in ln for ln in lines)
    uses_callbacks = any(
        re.search(r'\b(_ready|_process|_physics_process|_input)\b', ln) for ln in lines
    )
    uses_physics_move = any(
        "move_and_slide" in ln or "move_and_collide" in ln for ln in lines
    )

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
    )


def analyze_csharp_script(script_path: Path, project_root: Path) -> ScriptInfo:
    """
    Lightweight analyzer for Godot C# scripts.
    Mirrors the GDScript analyzer but uses C# syntax heuristics.
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
            extends = m.group(1)
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


def infer_tags_and_role(info: ScriptInfo) -> None:
    tags: Set[str] = set()

    # Dimensionality / type from extends.
    if info.extends:
        if "CharacterBody2D" in info.extends:
            tags.update(["2d", "movement", "character"])
        elif "CharacterBody3D" in info.extends:
            tags.update(["3d", "movement", "character"])
        elif "Node2D" in info.extends:
            tags.add("2d")
        elif "Node3D" in info.extends:
            tags.add("3d")
        elif "Control" in info.extends:
            tags.add("ui")

    # Path keywords.
    lower_path = info.rel_path.lower()
    if "player" in lower_path or "hero" in lower_path:
        tags.add("player")
    if "enemy" in lower_path or "mob" in lower_path:
        tags.update(["enemy", "ai"])
    if any(k in lower_path for k in ["ui", "menu", "hud", "pause"]):
        tags.update(["ui", "menu"])
    if any(k in lower_path for k in ["level", "world", "map"]):
        tags.add("level")

    # API usage tags.
    if info.uses_input:
        tags.add("input")
    if info.uses_signals:
        tags.add("signals")
    if info.uses_physics_move:
        tags.update(["physics", "movement"])

    info.tags = sorted(tags)

    # Simple role inference.
    role: Optional[str] = None
    if "2d" in tags and "movement" in tags and "character" in tags and "player" in tags:
        role = "2d_player_controller"
    elif "ui" in tags and "menu" in tags and "pause" in lower_path:
        role = "pause_menu_ui"
    elif "enemy" in tags and "ai" in tags and "2d" in tags:
        role = "basic_enemy_ai"
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


def copy_important_scripts(
    scripts: Dict[str, ScriptInfo],
    output_root: Path,
    importance_threshold: float,
    dry_run: bool,
) -> Dict[str, Dict]:
    """
    Copy scripts with importance >= threshold to output_root, preserving relative paths.
    Returns metadata dict keyed by rel_path.
    """
    meta: Dict[str, Dict] = {}
    for rel, info in scripts.items():
        if info.importance < importance_threshold:
            continue
        dst = output_root / rel
        if not dry_run:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(info.path, dst)
        # Persist ScriptInfo to metadata, but:
        # - Do NOT include local absolute paths.
        # - Normalize "path" to the project-relative path.
        # - Drop "role" for now (heuristics not reliable yet).
        info_dict = asdict(info)
        # Normalize path to rel_path for consumers and avoid leaking local disk paths.
        info_dict["path"] = rel
        # Remove raw filesystem path and role from serialized metadata.
        info_dict.pop("role", None)
        # Convert non-JSON-serializable values to plain types.
        if isinstance(info_dict.get("path"), Path):
            info_dict["path"] = str(info_dict["path"])
        # Convert any sets (e.g. referenced_by_scenes) to sorted lists.
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

    db_root = (Path(__file__).parent / ".." / ".." / ".." / "chroma_db").resolve()
    db_root.mkdir(parents=True, exist_ok=True)

    client = chromadb.PersistentClient(path=str(db_root))

    openai_api_key = os.getenv("OPENAI_API_KEY")
    openai_base_url = os.getenv("OPENAI_BASE_URL")
    embedding_fn = None
    if openai_api_key:
        embedding_fn = embedding_functions.OpenAIEmbeddingFunction(
            api_key=openai_api_key,
            model_name=os.getenv("OPENAI_EMBED_MODEL", "text-embedding-3-small"),
            api_base=openai_base_url or None,
        )

    # Use the same embedding configuration as the backend; if the collection
    # already exists with a different embedding function, fall back to the
    # existing one to avoid crashes (you can clear chroma_db/ to rebuild).
    try:
        collection = client.get_or_create_collection(
            "project_code", embedding_function=embedding_fn
        )
    except ValueError as e:
        log(f"[chroma] WARNING: embedding function conflict for 'project_code': {e}")
        collection = client.get_collection("project_code")

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

        ids.append(f"{project_slug}:{rel}")
        documents.append(text)
        tags = info.get("tags") or []
        md: Dict[str, object] = {
            "project_id": project_slug,
            "path": rel,
            "language": info.get("language", ""),
            "importance": info.get("importance", 0.0),
        }
        # Only include tags key if it is non-empty to satisfy Chroma's metadata validator.
        if tags:
            md["tags"] = tags
        metadatas.append(md)

    if not ids:
        log("[chroma] No valid documents collected for ChromaDB; nothing to add.")
        return

    log(f"[chroma] Indexing {len(ids)} documents into ChromaDB at {db_root}...")
    collection.add(ids=ids, documents=documents, metadatas=metadatas)
    log("[chroma] Indexing complete.")


def analyze_project(
    source_root: Path,
    output_root: Path,
    importance_threshold: float,
    slug: Optional[str],
    dry_run: bool,
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
    log(f"[analyze_project] Output root: {project_output_root}")

    # Copy only important scripts.
    meta = copy_important_scripts(
        scripts=scripts,
        output_root=project_output_root,
        importance_threshold=importance_threshold,
        dry_run=dry_run,
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

    # Write a minimal PROJECT.md summary for humans/LLMs.
    if not dry_run:
        project_output_root.mkdir(parents=True, exist_ok=True)

        # Simple PROJECT.md with a list of components.
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
    parser = argparse.ArgumentParser(
        description=(
            "Analyze a Godot project, score scripts by importance, "
            "and copy important scripts/shaders into the knowledge base."
        ),
        epilog=(
            "USAGE MODES:\n"
            "  1) Interactive (recommended while exploring):\n"
            "       python analyze_project.py\n"
            "     - Prompts for output root (demos folder).\n"
            "     - Optionally cleans that folder.\n"
            "     - Lets you set an importance threshold.\n"
            "     - Then you can enter project roots one by one until 'exit'.\n"
            "\n"
            "  2) Single project:\n"
            "       python analyze_project.py --source-root \"C:\\path\\to\\project\" \\\n"
        "         [--output-root \"C:\\path\\to\\godot_knowledge_base\\code\\demos\"] \\\n"
            "         [--importance-threshold 0.3] [--clean]\n"
            "\n"
            "  3) Batch directory of projects:\n"
            "       python analyze_project.py --projects-root \"C:\\path\\to\\projects\" \\\n"
        "         [--output-root \"C:\\path\\to\\godot_knowledge_base\\code\\demos\"] \\\n"
            "         [--importance-threshold 0.3] [--clean]\n"
            "\n"
            "DETAILS:\n"
            "  - Writes per-run logs under ./logs and opens the log in your editor on Windows.\n"
            "  - Only scripts/shaders with importance >= threshold are copied.\n"
            "  - Supports GDScript (*.gd), C# (*.cs), and shaders (*.gdshader).\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--source-root",
        type=str,
        help="Path to a Godot project root (contains project.godot).",
    )
    parser.add_argument(
        "--projects-root",
        type=str,
        help="If set, scan all subdirectories containing project.godot under this root.",
    )
    parser.add_argument(
        "--output-root",
        type=str,
        required=False,
        help=(
            "Output root under godot_knowledge_base/code "
            "(default: ../godot_knowledge_base/code/demos relative to this script)."
        ),
    )
    parser.add_argument(
        "--slug",
        type=str,
        help="Optional slug / project_id override for a single project.",
    )
    parser.add_argument(
        "--importance-threshold",
        type=float,
        default=0.3,
        help="Only scripts with importance >= this value will be copied (default: 0.3).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Analyze and print but do not write any files.",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help=(
            "If set, delete everything under --output-root before running. "
            "Use with care: this removes all existing demo outputs in that folder."
        ),
    )

    args = parser.parse_args()

    # Determine output_root: from CLI or default location.
    if args.output_root:
        output_root = Path(args.output_root).resolve()
    else:
        # Default to repo-relative demos folder:
        # rag_service/tools/project-parser/analyze_project.py
        #   -> ../../../godot_knowledge_base/code/demos
        base = Path(__file__).resolve()
        output_root = (base.parent / ".." / ".." / ".." / "godot_knowledge_base" / "code" / "demos").resolve()
        log(f"[main] Using default output root: {output_root}")

    # Optionally clean the output root before analysis.
    # Optionally clean the output root before analysis.
    clean_flag = args.clean
    # If no explicit flag and we're going to be interactive (no source/projects root),
    # ask the user once whether to clean.
    if not clean_flag and not args.source_root and not args.projects_root:
        answer = input(
            f"Clean output root first? This deletes everything under {output_root} (y/N): "
        ).strip().lower()
        clean_flag = answer in ("y", "yes")

    if clean_flag:
        if output_root.exists():
            log(f"[main] Cleaning output root: {output_root}")
            for child in output_root.iterdir():
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        else:
            log(f"[main] Output root does not exist, nothing to clean: {output_root}")

    # Decide mode: single source, batch, or interactive REPL-style.
    if args.source_root and args.projects_root:
        parser.error("Provide only one of --source-root or --projects-root, not both.")

    # Decide importance threshold; in interactive mode we can let the user override.
    importance_threshold = args.importance_threshold

    if args.source_root:
        # Single project mode. If the provided folder itself is not a Godot project
        # but contains multiple sub-projects, treat it like --projects-root.
        source_root = Path(args.source_root).resolve()
        if (source_root / "project.godot").exists():
            analyze_project(
                source_root=source_root,
                output_root=output_root,
                importance_threshold=importance_threshold,
                slug=args.slug,
                dry_run=args.dry_run,
            )
        else:
            # Fallback: scan this folder for nested projects.
            log(f"[main] No project.godot directly under {source_root}, scanning for nested projects...")
            project_count = 0
            for project_file in source_root.rglob("project.godot"):
                child = project_file.parent
                log(f"[main] Analyzing project: {child}")
                analyze_project(
                    source_root=child,
                    output_root=output_root,
                    importance_threshold=importance_threshold,
                    slug=None,
                    dry_run=args.dry_run,
                )
                project_count += 1
            if project_count == 0:
                log(f"[main] No Godot projects (project.godot) found under {source_root}")
    elif args.projects_root:
        # Batch mode over a directory tree of projects.
        projects_root = Path(args.projects_root).resolve()
        log(f"[main] Scanning for Godot projects under {projects_root} ...")
        # Recurse and treat any directory containing project.godot as a project root.
        project_count = 0
        for project_file in projects_root.rglob("project.godot"):
            child = project_file.parent
            log(f"[main] Analyzing project: {child}")
            analyze_project(
                source_root=child,
                output_root=output_root,
                importance_threshold=importance_threshold,
                slug=None,
                dry_run=args.dry_run,
            )
            project_count += 1
        if project_count == 0:
            log(f"[main] No Godot projects (project.godot) found under {projects_root}")
    else:
        # Interactive mode: prompt for project roots until the user exits.
        default_projects_root = Path(r"C:\Users\caweb\Desktop\godot-demo-projects")
        if default_projects_root.exists():
            log(
                "[main] Entering interactive mode. Press Enter to use the default "
                f"projects folder: {default_projects_root}"
            )
        else:
            log("[main] Entering interactive mode. Type a project root folder, or 'exit' to quit.")

        # Allow the user to override the importance threshold interactively.
        raw_thresh = input(
            f"Importance threshold [default {importance_threshold}]: "
        ).strip()
        if raw_thresh:
            try:
                importance_threshold = float(raw_thresh)
            except ValueError:
                log(
                    f"[main] Invalid threshold '{raw_thresh}', "
                    f"keeping default {importance_threshold}."
                )

        while True:
            try:
                prompt = "Project root (empty for default, or 'exit'): " if default_projects_root.exists() else "Project root (or 'exit'): "
                raw = input(prompt).strip()
            except (EOFError, KeyboardInterrupt):
                log("[main] Exiting interactive mode (keyboard interrupt).")
                break

            if not raw:
                if default_projects_root.exists():
                    source_root = default_projects_root
                else:
                    continue
            elif raw.lower() in ("exit", "quit"):
                log("[main] Exiting interactive mode.")
                break
            else:
                source_root = Path(raw).expanduser().resolve()

            # If the provided folder is not itself a project, scan for nested ones.
            if not (source_root / "project.godot").exists():
                log(f"[main] No project.godot directly under {source_root}, scanning for nested projects...")
                nested_count = 0
                for project_file in source_root.rglob("project.godot"):
                    child = project_file.parent
                    log(f"[main] Analyzing project: {child}")
                    analyze_project(
                        source_root=child,
                        output_root=output_root,
                        importance_threshold=importance_threshold,
                        slug=None,
                        dry_run=args.dry_run,
                    )
                    nested_count += 1
                if nested_count == 0:
                    log(f"[main] No Godot projects (project.godot) found under {source_root}")
                continue

            analyze_project(
                source_root=source_root,
                output_root=output_root,
                importance_threshold=importance_threshold,
                slug=None,
                dry_run=args.dry_run,
            )
    log("[main] Analysis completed successfully.")


if __name__ == "__main__":
    main()

