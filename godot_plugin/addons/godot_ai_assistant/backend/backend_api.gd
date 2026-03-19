@tool
extends RefCounted
class_name GodotAIBackendAPI

## Backend API: query for tools, log edit events, post lint fix.
## Uses BackendClient and ContextPayload.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func query_backend_for_tools(
	question: String,
	lint_output: String = "",
	override_file_path: String = "",
	override_file_text: String = ""
) -> Dictionary:
	_dock.set_last_tool_prompt(question)
	_dock.set_last_tool_trigger("tool_action")
	var settings := _dock.get_settings()
	var profile := GodotAIBackendProfile.get_profile(settings.backend_profile_id)
	var endpoint := profile.get_query_url(_dock.rag_service_url)
	var conv_messages: Array = _dock.get_current_chat_conversation_messages()
	var ctx: Dictionary = GodotAIContextPayload.build(
		_dock.get_editor_interface_ref(),
		override_file_path,
		override_file_text,
		lint_output,
		conv_messages
	)
	var exclude_keys: Array = _dock.get_current_chat_exclude_context_keys()
	if not ctx.has("extra"):
		ctx["extra"] = {}
	ctx["extra"] = (ctx["extra"] as Dictionary).duplicate()

	# Repair memory (lint repair suggestions) is client-owned:
	# - plugin computes it from local lint_memory_store
	# - backend app/main injects it into the context without querying its own SQLite.
	if not lint_output.is_empty():
		var store = _dock.get_lint_memory_store()
		if store != null:
			var engine_version = Engine.get_version_info().get("string")
			var fixes = store.search_fixes(str(engine_version), lint_output, 3)
			var block = store.format_fixes_for_prompt(fixes)
			if not block.is_empty():
				(ctx["extra"] as Dictionary)["lint_repair_memory"] = block

	# Repo index (structural proximity) is client-owned:
	# plugin computes one-hop related res:// paths and sends them to the backend,
	# which uses them instead of querying SQLite-backed repo_indexing.
	var active_file_res_path = str(ctx.get("current_script", ""))
	if not active_file_res_path.is_empty():
		var repo_store = _dock.get_repo_index_store()
		if repo_store != null:
			var related_paths = repo_store.get_related_res_paths_one_hop(active_file_res_path, 4)
			if related_paths.size() > 0:
				(ctx["extra"] as Dictionary)["related_res_paths"] = related_paths

	if exclude_keys.size() > 0:
		ctx["extra"]["exclude_block_keys"] = exclude_keys
	var chat_id: String = _dock.get_current_chat_id()
	if not chat_id.is_empty():
		ctx["extra"]["chat_id"] = chat_id
	var payload: Dictionary = _build_query_payload(question, ctx, settings)
	# Composer v2 requires an explicit mode so the model knows whether to emit tool calls.
	# query_backend_for_tools always executes tool calls, so we default to AGENT mode.
	if (profile.profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER):
		payload["composer_mode"] = "agent"
	var body := JSON.stringify(payload)
	var data = await GodotAIBackendClient.query_json(
		_dock, endpoint, HTTPClient.METHOD_POST, body
	)
	return data if data is Dictionary else {}


## Build the JSON payload for any query endpoint (RAG or Composer).
## Same shape: question, context, top_k, api_key, model, base_url.
func _build_query_payload(question: String, context: Dictionary, settings: GodotAISettings) -> Dictionary:
	var payload: Dictionary = {
		"question": question,
		"context": context,
		"top_k": 8
	}
	if settings:
		if settings.openai_api_key.length() > 0:
			payload["api_key"] = settings.openai_api_key
		var model := settings.get_effective_model()
		if model.length() > 0:
			payload["model"] = model
		if settings.openai_base_url.length() > 0:
			payload["base_url"] = settings.openai_base_url
	return payload


func log_edit_event_to_backend(
	edit_records: Array,
	trigger: String = "tool_action",
	prompt: String = "",
	lint_errors_before: String = "",
	lint_errors_after: String = ""
) -> void:
	var endpoint := _dock.rag_service_url + "/edit_events/create"
	var changes: Array = []
	for r in edit_records:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		changes.append({
			"file_path": str(r.get("file_path", "")),
			"change_type": str(r.get("change_type", "modify")),
			"old_content": str(r.get("old_content", "")),
			"new_content": str(r.get("new_content", "")),
		})
	if changes.is_empty():
		return

	var summary := "Edited %d file(s)" % changes.size()
	if changes.size() == 1:
		var c0: Dictionary = changes[0]
		summary = "%s %s" % [str(c0.get("change_type", "modify")), str(c0.get("file_path", ""))]

	var payload: Dictionary = {
		"actor": "ai",
		"trigger": trigger if not trigger.is_empty() else "tool_action",
		"summary": summary,
		"changes": changes,
	}
	if not prompt.is_empty():
		payload["prompt"] = prompt
	if not lint_errors_before.is_empty():
		payload["lint_errors_before"] = lint_errors_before
	if not lint_errors_after.is_empty():
		payload["lint_errors_after"] = lint_errors_after
	var body := JSON.stringify(payload)
	await GodotAIBackendClient.post_fire_and_forget(_dock, endpoint, body)


func post_lint_fix_to_backend(
	file_path: String,
	lint_output: String,
	old_content: String,
	new_content: String,
	prompt: String
) -> void:
	var endpoint := _dock.rag_service_url + "/lint_memory/record_fix"
	var payload: Dictionary = {
		"project_root_abs": ProjectSettings.globalize_path("res://"),
		"file_path": file_path,
		"engine_version": Engine.get_version_info().get("string"),
		"raw_lint_output": lint_output,
		"old_content": old_content,
		"new_content": new_content,
		"prompt": prompt,
	}
	var body := JSON.stringify(payload)
	await GodotAIBackendClient.post_fire_and_forget(_dock, endpoint, body)
