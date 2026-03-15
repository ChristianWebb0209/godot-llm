# Context-building services: budget, scene, project, docs, code_samples, conversation.
# Public API is re-exported from app.context_builder for backward compatibility.

from .viewer import build_context_view

from .budget import (
    PRIORITY_ACTIVE_FILE,
    PRIORITY_COMPONENT_SCRIPTS,
    PRIORITY_CURRENT_SCENE_SCRIPTS,
    PRIORITY_ENV,
    PRIORITY_ERRORS,
    PRIORITY_EXTRAS,
    PRIORITY_KNOWLEDGE,
    PRIORITY_RECENT,
    PRIORITY_RELATED,
    PRIORITY_TASK,
    ContextBlock,
    ContextUsage,
    build_context_usage,
    blocks_to_user_content,
    estimate_tokens,
    fit_block_text,
    get_context_limit,
    trim_text_to_tokens,
)
from .code_samples import format_component_scripts_block, SCRAPED_CODE_DISCLAIMER
from .conversation import build_conversation_context
from .docs import build_knowledge_block_parts
from .project import (
    append_project_file,
    apply_project_patch,
    apply_project_patch_unified,
    build_related_files_context,
    list_project_directory,
    list_project_files,
    read_project_file,
    search_project_files,
    write_project_file,
)
from .scene import (
    build_current_scene_scripts_context,
    extract_extends_from_script,
    parse_tscn_script_paths,
)

__all__ = [
    "append_project_file",
    "apply_project_patch",
    "apply_project_patch_unified",
    "build_context_view",
    "PRIORITY_COMPONENT_SCRIPTS",
    "PRIORITY_CURRENT_SCENE_SCRIPTS",
    "PRIORITY_ENV",
    "PRIORITY_ERRORS",
    "PRIORITY_EXTRAS",
    "PRIORITY_KNOWLEDGE",
    "PRIORITY_RECENT",
    "PRIORITY_RELATED",
    "PRIORITY_TASK",
    "ContextBlock",
    "ContextUsage",
    "build_context_usage",
    "blocks_to_user_content",
    "build_conversation_context",
    "build_current_scene_scripts_context",
    "build_knowledge_block_parts",
    "build_related_files_context",
    "format_component_scripts_block",
    "list_project_directory",
    "search_project_files",
    "SCRAPED_CODE_DISCLAIMER",
    "extract_extends_from_script",
    "estimate_tokens",
    "fit_block_text",
    "get_context_limit",
    "list_project_files",
    "parse_tscn_script_paths",
    "read_project_file",
    "trim_text_to_tokens",
    "write_project_file",
]
