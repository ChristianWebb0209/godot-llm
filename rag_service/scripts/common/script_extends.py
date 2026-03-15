"""
Shared logic to infer the Godot "component" (extends class) from script content.
Used by fetch_top_godot_repos (by-component folder layout) and analyze_project (index metadata).
"""
from pathlib import Path
import re
from typing import Set

# Known Godot C# base types (engine nodes/resources). Normalized names only (no "Godot." prefix).
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

# All Godot engine (native) extends: for filtering so we only bucket native types.
# Includes C# set plus common GDScript/engine Control/Container/UI and Scene (for .tscn).
GODOT_NATIVE_EXTENDS: Set[str] = GODOT_CSHARP_BASE_TYPES | {
    "AcceptDialog", "ConfirmationDialog", "FileDialog", "Window",
    "Container", "HBoxContainer", "VBoxContainer", "MarginContainer", "GridContainer",
    "Panel", "PanelContainer", "CenterContainer", "BoxContainer",
    "ProgressBar", "CheckButton", "Button", "Label", "LineEdit", "TextEdit",
    "Tree", "ItemList", "PopupMenu", "MenuButton", "OptionButton",
    "SplitContainer", "HSplitContainer", "VSplitContainer", "ScrollContainer",
    "Theme", "Reference",  # Reference = Godot 3 RefCounted alias
    "Scene",  # bucket for .tscn
}

_GDSCRIPT_EXTENDS_RE = re.compile(r'^\s*extends\s+([A-Za-z0-9_".]+)')
_CSHARP_CLASS_RE = re.compile(
    r'^\s*(?:public\s+|internal\s+|partial\s+)*class\s+[A-Za-z0-9_]+\s*:\s*([A-Za-z0-9_\.]+)'
)


def is_native_godot_extends(extends_name: str) -> bool:
    """Return True if the given extends/class name is a Godot engine (native) type."""
    if not extends_name or not extends_name.strip():
        return False
    return extends_name.strip() in GODOT_NATIVE_EXTENDS


def _normalize_csharp_extends(base: str) -> str:
    """Strip Godot. prefix so extends_class matches GDScript and docs."""
    if not base:
        return ""
    s = base.strip()
    if s.startswith("Godot."):
        return s[6:].strip()
    return s


def get_extends_from_content(content: str, path: str | Path) -> str:
    """
    Infer the component (extends class) from file content and path.
    - .gd: first `extends TypeName` in first ~20 lines; default "Node" if missing.
    - .cs: first `class Name : BaseType` in first ~50 lines; normalize Godot. prefix;
      if base is not in GODOT_CSHARP_BASE_TYPES, return "Node" (bucket for non-Godot C#).
    - .gdshader: return "Shader".
    - .tscn: return "Scene".

    Returns a string suitable for folder names and index keys (e.g. CharacterBody2D, Node, Shader).
    """
    path = Path(path) if not isinstance(path, Path) else path
    suffix = (path.suffix or "").lower()
    lines = content.splitlines()

    if suffix == ".gd":
        for ln in lines[:20]:
            m = _GDSCRIPT_EXTENDS_RE.match(ln)
            if m:
                name = m.group(1).strip('"')
                return name if is_native_godot_extends(name) else "Other"
        return "Node"

    if suffix == ".cs":
        for ln in lines[:50]:
            m = _CSHARP_CLASS_RE.match(ln)
            if m:
                raw = m.group(1)
                normalized = _normalize_csharp_extends(raw)
                if normalized in GODOT_CSHARP_BASE_TYPES:
                    return normalized
                return "Other"  # non-Godot C# go to Other
        return "Node"

    if suffix == ".gdshader":
        return "Shader"
    if suffix == ".tscn":
        return "Scene"

    return "Node"
