@tool
extends RefCounted
class_name GodotAIBackendProfile

## Defines how the plugin talks to a backend: endpoint paths and payload shape.
## Use get_profile(id) and get_all_profiles() to support multiple backends (RAG vs Godot Composer).

const PROFILE_RAG := "rag"
const PROFILE_GODOT_COMPOSER := "godot_composer"

## Endpoint path relative to base URL (e.g. rag_service_url). No leading slash.
var query_path: String = "/query"
var stream_path: String = "/query_stream"
var stream_with_tools_path: String = "/query_stream_with_tools"

## Display name for UI.
var display_name: String = "RAG (OpenAI)"
## Unique id for persistence.
var profile_id: String = PROFILE_RAG

## If true, backend returns tool_calls directly from the model (e.g. fine-tuned Godot Composer).
## Plugin still expects same response shape: answer + tool_calls array.
var returns_tool_calls_directly: bool = false


static func get_all_profiles() -> Array:
	var list: Array = []
	list.append(_make_rag_profile())
	list.append(_make_composer_profile())
	return list


static func get_profile(profile_id: String) -> GodotAIBackendProfile:
	for p in get_all_profiles():
		if (p as GodotAIBackendProfile).profile_id == profile_id:
			return p as GodotAIBackendProfile
	return _make_rag_profile()


static func _make_rag_profile() -> GodotAIBackendProfile:
	var p := GodotAIBackendProfile.new()
	p.profile_id = PROFILE_RAG
	p.display_name = "RAG (OpenAI)"
	p.query_path = "/query"
	p.stream_path = "/query_stream"
	p.stream_with_tools_path = "/query_stream_with_tools"
	p.returns_tool_calls_directly = false
	return p


static func _make_composer_profile() -> GodotAIBackendProfile:
	var p := GodotAIBackendProfile.new()
	p.profile_id = PROFILE_GODOT_COMPOSER
	p.display_name = "Godot Composer"
	p.query_path = "/composer/query"
	p.stream_path = "/composer/query_stream"
	p.stream_with_tools_path = "/composer/query_stream_with_tools"
	p.returns_tool_calls_directly = true
	return p


## Build full URL for a given path key. base_url should not have trailing slash.
func get_query_url(base_url: String) -> String:
	var path := query_path if query_path.begins_with("/") else ("/" + query_path)
	return base_url.strip_edges().trim_suffix("/") + path


func get_stream_url(base_url: String) -> String:
	var path := stream_path if stream_path.begins_with("/") else ("/" + stream_path)
	return base_url.strip_edges().trim_suffix("/") + path


func get_stream_with_tools_url(base_url: String) -> String:
	var path := stream_with_tools_path
	if not path.begins_with("/"):
		path = "/" + path
	return base_url.strip_edges().trim_suffix("/") + path
