@tool
extends RefCounted
class_name GodotAIChatStreaming

## Controller: chat send + streaming pipeline.
##
## Owns streaming UX and backend request orchestration for chat messages.
## It may call back into the dock for UI updates, but it should not “own” UI nodes.

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func on_ask_pressed() -> void:
	_dock._ensure_default_chat()
	# Stop (interject): cancel the stream and cue user to type a quick fix in the same thread.
	if _dock._streaming_in_progress and _dock._streaming_chat_index == _dock.get_current_chat():
		_dock._stream_generation += 1
		_dock._streaming_in_progress = false
		_dock._streaming_chat_index = -1
		_dock._chat_ux.update_ask_button_state()
		_dock._activity_state.clear_activity()
		_dock._on_interject_stopped()
		return
	var question: String = _dock.prompt_text_edit.text.strip_edges()
	if question.is_empty():
		_dock.set_status("Please enter a question.")
		return
	if _dock._streaming_in_progress:
		_dock._stream_generation += 1
	_dock.set_last_tool_prompt(question)
	_dock.set_last_tool_trigger("tool_action")
	_dock._lint_follow_up_count_this_turn = 0
	_dock.ensure_chat_has_messages_internal()
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		messages[messages.size() - 1]["activity_history"] = _dock.get_activity_history().duplicate()
	var now_ts := int(Time.get_unix_time_from_system())
	_dock.get_chats()[_dock.get_current_chat()]["messages"].append({"role": "user", "text": question, "ts": now_ts})
	_dock.get_chats()[_dock.get_current_chat()]["messages"].append({"role": "assistant", "text": "", "ts": now_ts})
	_dock._streamed_markdown = ""
	_dock._tw_visible = 0
	_dock._tw_active_chat_index = _dock.get_current_chat()
	_dock._save_current_chat_activity()
	_dock._clear_activity()
	if _dock.thought_history_list:
		_dock.thought_history_list.visible = false
	_dock._activity_state.update_activity_ui()
	_dock._activity_state.push_activity("Preparing...")
	_dock._chat_renderer.render_chat_log()
	_dock._chat_ux.scroll_output_to_bottom()
	if _dock.prompt_text_edit:
		_dock.prompt_text_edit.text = ""
	_dock.call_deferred("_deferred_send_question", question, true)


func send_user_message(question: String) -> void:
	question = question.strip_edges()
	if question.is_empty():
		_dock.set_status("Please enter a question.")
		return
	_dock._ensure_default_chat()
	if _dock.get_current_chat() < 0 or _dock.get_current_chat() >= _dock.get_chats().size():
		return
	if _dock._streaming_in_progress and _dock._streaming_chat_index == _dock.get_current_chat():
		_dock._stream_generation += 1
		_dock._streaming_in_progress = false
		_dock._streaming_chat_index = -1
		_dock._chat_ux.update_ask_button_state()
		_dock._activity_state.clear_activity()
		_dock._on_interject_stopped()
		return
	if _dock._streaming_in_progress:
		_dock._stream_generation += 1
	_dock.set_last_tool_prompt(question)
	_dock.set_last_tool_trigger("tool_action")
	_dock._lint_follow_up_count_this_turn = 0
	_dock.ensure_chat_has_messages_internal()
	var messages: Array = _dock.get_chats()[_dock.get_current_chat()]["messages"]
	if messages.size() > 0 and messages[messages.size() - 1].get("role", "") == "assistant":
		messages[messages.size() - 1]["activity_history"] = _dock.get_activity_history().duplicate()
	var now_ts := int(Time.get_unix_time_from_system())
	_dock.get_chats()[_dock.get_current_chat()]["messages"].append({"role": "user", "text": question, "ts": now_ts})
	_dock.get_chats()[_dock.get_current_chat()]["messages"].append({"role": "assistant", "text": "", "ts": now_ts})
	_dock._streamed_markdown = ""
	_dock._tw_visible = 0
	_dock._tw_active_chat_index = _dock.get_current_chat()
	_dock._save_current_chat_activity()
	_dock._clear_activity()
	if _dock.thought_history_list:
		_dock.thought_history_list.visible = false
	_dock._activity_state.update_activity_ui()
	_dock._activity_state.push_activity("Preparing...")
	_dock._chat_renderer.render_chat_log()
	_dock._chat_ux.scroll_output_to_bottom()
	_dock.call_deferred("_deferred_send_question", question, true)


func deferred_send_question(
	question: String,
	use_tools: bool,
	override_file_path: String = "",
	override_file_text: String = "",
	lint_output_override: String = ""
) -> void:
	_dock._activity_state.push_activity("Building context...")
	var conversation_messages: Array = []
	if _dock.get_current_chat() >= 0 and _dock.get_current_chat() < _dock.get_chats().size():
		conversation_messages = _dock.get_chats()[_dock.get_current_chat()].get("messages", [])
	var context: Dictionary = GodotAIContextPayload.build(
		_dock.get_editor_interface_ref(),
		override_file_path,
		override_file_text,
		lint_output_override if not lint_output_override.is_empty() else "",
		conversation_messages
	)
	var current_script: String = str(context.get("current_script", ""))
	if not context.has("extra"):
		context["extra"] = {}
	if not lint_output_override.is_empty():
		context["extra"]["lint_output"] = lint_output_override
	elif _dock._last_lint_path and str(current_script) == str(_dock._last_lint_path) and not _dock._last_lint_output.is_empty():
		context["extra"]["lint_output"] = _dock._last_lint_output

	# Repair memory (lint repair suggestions) is computed locally in the plugin.
	# If we have lint_output in the context, we search the local lint memory store
	# and inject `lint_repair_memory` into the context extras.
	var lint_out_for_memory = str((context["extra"] as Dictionary).get("lint_output", ""))
	if not lint_out_for_memory.is_empty():
		var store = _dock.get_lint_memory_store()
		if store != null:
			var engine_version = Engine.get_version_info().get("string")
			var fixes = store.search_fixes(str(engine_version), lint_out_for_memory, 3)
			var block = store.format_fixes_for_prompt(fixes)
			if not block.is_empty():
				context["extra"]["lint_repair_memory"] = block

	# Repo index (structural proximity) is client-owned:
	# plugin computes one-hop related res:// paths and sends them in context.extra,
	# so backend can avoid SQLite-backed repo_indexing queries.
	var active_file_res_path = str(context.get("current_script", ""))
	if not active_file_res_path.is_empty():
		var repo_store = _dock.get_repo_index_store()
		if repo_store != null:
			var related_paths = repo_store.get_related_res_paths_one_hop(active_file_res_path, 4)
			if related_paths.size() > 0:
				context["extra"]["related_res_paths"] = related_paths

	var exclude_keys: Array = _dock.get_current_chat_exclude_context_keys()
	if exclude_keys.size() > 0:
		context["extra"]["exclude_block_keys"] = exclude_keys
	var chat_id_str: String = _dock.get_current_chat_id()
	if not chat_id_str.is_empty():
		context["extra"]["chat_id"] = chat_id_str
	var pinned_extra: Dictionary = _dock._build_pinned_context_extra()
	for k in pinned_extra:
		context["extra"][k] = pinned_extra[k]
	var payload: Dictionary = {"question": question, "context": context, "top_k": 8}
	var settings := _dock.get_settings()
	if settings:
		if settings.openai_api_key.length() > 0:
			payload["api_key"] = settings.openai_api_key
		var model := settings.get_effective_model()
		if model.length() > 0:
			payload["model"] = model
		if settings.openai_base_url.length() > 0:
			payload["base_url"] = settings.openai_base_url
	# Composer v2 requires a mode: agent (tool calls) vs ask (no tool calls).
	# We map this to `use_tools`: when tools are enabled, we expect the model to emit tool_call blocks.
	if settings and settings.backend_profile_id == GodotAIBackendProfile.PROFILE_GODOT_COMPOSER:
		payload["composer_mode"] = ("agent" if use_tools else "ask")
	var json_body: String = JSON.stringify(payload)
	var profile_id: String = settings.backend_profile_id if settings else GodotAIBackendProfile.PROFILE_RAG
	var profile := GodotAIBackendProfile.get_profile(profile_id)
	var stream_endpoint: String = profile.get_stream_with_tools_url(_dock.rag_service_url) if use_tools else profile.get_stream_url(_dock.rag_service_url)
	_dock._stream_start_generation = _dock._stream_generation
	_dock._stream_message_index = _dock.get_chats()[_dock.get_current_chat()]["messages"].size() - 1
	_dock._streaming_in_progress = true
	_dock._streaming_chat_index = _dock.get_current_chat()
	_dock._chat_ux.update_ask_button_state()
	_dock._activity_state.push_activity("Calling AI...")
	async_stream_request(stream_endpoint, json_body)


func async_stream_request(endpoint: String, body: String) -> void:
	var cancel_check := Callable(_dock, "_is_stream_cancelled")
	await GodotAIBackendClient.stream_post(
		_dock,
		endpoint,
		body,
		Callable(self, "on_stream_chunk"),
		Callable(self, "on_stream_done"),
		cancel_check
	)


func parse_think_and_answer(raw: String) -> Dictionary:
	const THINK_OPEN := "<think>"
	const THINK_CLOSE := "</think>"
	var reasoning := ""
	var answer := ""
	var i := raw.find(THINK_OPEN)
	if i < 0:
		answer = raw
		return { "reasoning": reasoning, "answer": answer }
	var leading := raw.substr(0, i)
	var j := raw.find(THINK_CLOSE, i)
	if j < 0:
		reasoning = raw.substr(i + THINK_OPEN.length())
		answer = leading
		return { "reasoning": reasoning, "answer": answer }
	reasoning = raw.substr(i + THINK_OPEN.length(), j - i - THINK_OPEN.length())
	answer = leading + raw.substr(j + THINK_CLOSE.length())
	return { "reasoning": reasoning.strip_edges(), "answer": answer }


static func extract_tool_calls_and_usage(full_text: String) -> Dictionary:
	# Contract helper for tests and robust marker parsing.
	var normalized_full_text := full_text.replace("\r\n", "\n").replace("\r", "\n")
	const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
	const USAGE_MARKER := "\n__USAGE__\n"

	var marker_pos := normalized_full_text.find(TOOL_CALLS_MARKER)
	if marker_pos < 0:
		return { "tool_calls_json": "", "usage_json": "" }

	var tail := normalized_full_text.substr(marker_pos + TOOL_CALLS_MARKER.length())
	var usage_pos := tail.find(USAGE_MARKER)

	var tool_calls_json := tail.strip_edges()
	var usage_json := ""
	if usage_pos >= 0:
		tool_calls_json = tail.substr(0, usage_pos).strip_edges()
		usage_json = tail.substr(usage_pos + USAGE_MARKER.length()).strip_edges()

	return {
		"tool_calls_json": tool_calls_json,
		"usage_json": usage_json,
	}


func on_stream_chunk(delta: String) -> void:
	if _dock._stream_start_generation != _dock._stream_generation:
		return
	if _dock._streaming_chat_index < 0 or _dock._streaming_chat_index >= _dock.get_chats().size():
		return
	var is_first_chunk: bool = _dock._streamed_markdown.is_empty()
	if is_first_chunk:
		_dock._activity_state.push_activity("Streaming response...")
		_dock.ensure_chat_has_messages_internal()
	# Keep accumulating streamed content so parse/render state stays correct.
	_dock._streamed_markdown += _normalize_newlines(delta)
	var messages: Array = _dock.get_chats()[_dock._streaming_chat_index]["messages"]
	if (
		_dock._stream_message_index >= 0
		and _dock._stream_message_index < messages.size()
		and messages[_dock._stream_message_index].get("role", "") == "assistant"
	):
		var parsed := parse_think_and_answer(_dock._streamed_markdown)
		messages[_dock._stream_message_index]["reasoning"] = parsed.reasoning
		const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
		var answer: String = parsed.answer
		var marker_pos: int = answer.find(TOOL_CALLS_MARKER)
		messages[_dock._stream_message_index]["text"] = answer.substr(0, marker_pos) if marker_pos >= 0 else answer
	if is_first_chunk:
		_dock._tw_visible = 0
		if _dock._streaming_chat_index == _dock.get_current_chat():
			_dock._chat_renderer.render_chat_log()
	if _dock._typewriter_timer != null:
		_dock._typewriter_timer.start()


func on_stream_done(full_text: String, error_message: String = "") -> void:
	if _dock._stream_start_generation != _dock._stream_generation:
		return
	if not error_message.is_empty():
		_dock.set_status(error_message)
		_dock._append_error_to_chat(error_message)
		_dock._streaming_in_progress = false
		_dock._chat_ux.update_ask_button_state()
		_dock._activity_state.clear_activity()
		return
	if full_text.is_empty():
		_dock.set_status("Request ended with no response. (Cancelled or connection lost.)")
		_dock._streaming_in_progress = false
		_dock._chat_ux.update_ask_button_state()
		_dock._clear_activity()
		return
	var normalized_full_text := _normalize_newlines(full_text)
	_dock._streamed_markdown = normalized_full_text
	const TOOL_CALLS_MARKER := "\n__TOOL_CALLS__\n"
	const USAGE_MARKER := "\n__USAGE__\n"
	var sci: int = _dock._streaming_chat_index if _dock._streaming_chat_index >= 0 else _dock.get_current_chat()
	var parsed := parse_think_and_answer(_dock._streamed_markdown)
	var answer_part: String = parsed.answer
	var marker_pos: int = answer_part.find(TOOL_CALLS_MARKER)
	var display_text: String = answer_part.substr(0, marker_pos) if marker_pos >= 0 else answer_part
	_dock._streamed_markdown = display_text
	_dock.ensure_chat_has_messages_internal()
	if sci >= 0 and sci < _dock.get_chats().size():
		var messages: Array = _dock.get_chats()[sci]["messages"]
		if (
			_dock._stream_message_index >= 0
			and _dock._stream_message_index < messages.size()
			and messages[_dock._stream_message_index].get("role", "") == "assistant"
		):
			messages[_dock._stream_message_index]["reasoning"] = parsed.reasoning
			messages[_dock._stream_message_index]["text"] = display_text
		_dock._maybe_update_chat_title_from_answer(sci)
		if sci == _dock.get_current_chat():
			_dock._chat_renderer.render_chat_log()
	if marker_pos >= 0:
		var extracted := extract_tool_calls_and_usage(normalized_full_text)
		var tool_calls_payload: String = extracted.get("tool_calls_json", "")
		var usage_json: String = extracted.get("usage_json", "")
		if sci >= 0 and sci < _dock.get_chats().size():
			var messages2: Array = _dock.get_chats()[sci]["messages"]
			if not tool_calls_payload.is_empty():
				var parsed_tool_calls := _parse_tool_calls_payload(tool_calls_payload)
				var tool_arr: Array = parsed_tool_calls.get("tool_arr", []) as Array
				var tool_parse_error: String = parsed_tool_calls.get("error", "") as String
				if tool_parse_error.is_empty() and tool_arr.size() > 0:
					var summaries: Array = _dock._format_tool_calls_summaries(tool_arr)
					if (
						_dock._stream_message_index >= 0
						and _dock._stream_message_index < messages2.size()
						and messages2[_dock._stream_message_index].get("role", "") == "assistant"
					):
						messages2[_dock._stream_message_index]["tool_calls_summary"] = summaries
					_dock._update_tool_calls_ui()
					# Dispatch tool calls via the dock so tool execution + lint follow-ups work.
					_dock.run_editor_actions_async.call_deferred(
						tool_arr,
						false,
						"tool_action",
						_dock._last_tool_prompt,
						"",
						""
					)
				else:
					var preview := tool_calls_payload
					if preview.length() > 500:
						preview = preview.substr(0, 497) + "..."
					_dock.set_status("Tool calls marker found, but tool_calls JSON could not be parsed.")
					_dock.append_error_to_chat(
						"**Tool calls parse error**" +
						("" if tool_parse_error.is_empty() else (" " + tool_parse_error)) +
						"\n\nRaw (preview):\n```\n" + preview + "\n```"
					)
			if sci == _dock.get_current_chat():
				_dock._chat_renderer.render_chat_log()
		if not usage_json.is_empty():
			var uj := JSON.new()
			if uj.parse(usage_json) == OK and uj.data is Dictionary and sci >= 0 and sci < _dock.get_chats().size():
				_dock.get_chats()[sci]["context_usage"] = uj.data
				var us = _dock.get_usage_store()
				if us != null:
					var model := str(uj.data.get("model", ""))
					var est_prompt := int(uj.data.get("estimated_prompt_tokens", 0))
					us.record_usage(model, est_prompt, 0)
				_dock._chat_ux.update_context_usage_label()
				if _dock.context_viewer_panel and _dock.context_viewer_panel.visible:
					_dock._refresh_context_viewer_panel()
	_dock._streaming_in_progress = false
	_dock._streaming_chat_index = -1
	_dock._chat_ux.update_ask_button_state()
	_dock._activity_state.clear_activity()
	if _dock._typewriter_timer != null:
		_dock._typewriter_timer.start()


func _normalize_newlines(s: String) -> String:
	# Make marker matching consistent across backends/platforms that emit \r\n.
	return s.replace("\r\n", "\n").replace("\r", "\n")


static func _parse_tool_calls_payload(payload: String) -> Dictionary:
	# Supports both:
	# - marker-based JSON array (current contract)
	# - XML <tool_call>{...json...}</tool_call> blocks (newer backend variants)
	var normalized := payload.replace("\r\n", "\n").replace("\r", "\n").strip_edges()
	if normalized.is_empty():
		return { "tool_arr": [], "error": "" }

	var json := JSON.new()
	if json.parse(normalized) == OK and json.data is Array:
		return { "tool_arr": json.data, "error": "" }

	# If it's not a JSON array, try parsing the tool_call XML blocks.
	var tool_arr := _parse_tool_calls_from_xml(normalized)
	if tool_arr.size() > 0:
		return { "tool_arr": tool_arr, "error": "" }

	# Best-effort error detail.
	var err_detail := "Expected JSON array or <tool_call> XML blocks."
	return { "tool_arr": [], "error": err_detail }


static func _parse_tool_calls_from_xml(xml_text: String) -> Array:
	var out: Array = []
	if xml_text.find("<tool_call") < 0:
		return out

	var re := RegEx.new()
	# (?s) makes '.' match newlines.
	if re.compile("(?s)<tool_call>\\s*(.*?)\\s*</tool_call>") != OK:
		return out

	var matches: Array = re.search_all(xml_text)
	for m in matches:
		if m == null:
			continue
		var inner := str(m.get_string(1)).strip_edges()
		if inner.is_empty():
			continue
		var j := JSON.new()
		if j.parse(inner) != OK:
			continue
		if typeof(j.data) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = j.data
		var name := str(d.get("name", d.get("tool_name", "")))
		if name.is_empty():
			continue
		var args_val := d.get("arguments", d.get("args", {}))
		var args: Dictionary = args_val if typeof(args_val) == TYPE_DICTIONARY else {}
		out.append({"tool_name": name, "arguments": args})
	return out

