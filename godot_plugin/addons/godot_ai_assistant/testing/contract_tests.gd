extends Node

## Headless contract tests for client-side parsing + tool schema mapping.
##
## Run (from repo root):
##   godot --headless --quit --script res://addons/godot_ai_assistant/testing/contract_tests.gd

func _ready() -> void:
	var failures: Array[String] = []

	# (a) parse_think_and_answer
	var streamer := GodotAIChatStreaming.new(null)

	var t0 := streamer.parse_think_and_answer("Hello world")
	if str(t0.get("reasoning", "")) != "":
		failures.append("parse_think_and_answer: expected empty reasoning for no <think> block")
	if str(t0.get("answer", "")) != "Hello world":
		failures.append("parse_think_and_answer: expected full string as answer when no <think> block")

	var t1 := streamer.parse_think_and_answer("<think>r</think>Answer")
	if str(t1.get("reasoning", "")) != "r":
		failures.append("parse_think_and_answer: expected reasoning 'r'")
	if str(t1.get("answer", "")) != "Answer":
		failures.append("parse_think_and_answer: expected answer 'Answer'")

	# (b) Streaming marker extraction + tool_calls JSON validity
	var full_text := "prefix <think>r</think>Answer A\n__TOOL_CALLS__\r\n[{\"tool_name\":\"write_file\",\"arguments\":{\"path\":\"res://a.gd\",\"content\":\"print(1)\"}}]\r\n__USAGE__\r\n{\"model\":\"m\",\"estimated_prompt_tokens\":123}\r\n"

	var extracted := GodotAIChatStreaming.extract_tool_calls_and_usage(full_text)
	var tool_calls_json: String = str(extracted.get("tool_calls_json", ""))
	var usage_json: String = str(extracted.get("usage_json", ""))

	if tool_calls_json.is_empty():
		failures.append("extract_tool_calls_and_usage: tool_calls_json empty")
	if usage_json.is_empty():
		failures.append("extract_tool_calls_and_usage: usage_json empty")

	var tool_json := JSON.new()
	if tool_json.parse(tool_calls_json) != OK or not (tool_json.data is Array):
		failures.append("extract_tool_calls_and_usage: tool_calls_json not valid Array JSON")

	if tool_json.data is Array:
		var arr: Array = tool_json.data
		if arr.size() != 1:
			failures.append("extract_tool_calls_and_usage: expected 1 tool call")

	var usage_obj := JSON.new()
	if usage_obj.parse(usage_json) != OK or not (usage_obj.data is Dictionary):
		failures.append("extract_tool_calls_and_usage: usage_json not valid Dictionary JSON")

	# (c) Tool schema mapping in tool_runner.gd
	var tc1 := {
		"tool_name": "write_file",
		"arguments": { "path": "res://a.gd", "content": "print(1)" },
	}
	var payload1 := GodotAIToolRunner.executor_payload_from_tool_call(tc1)
	if str(payload1.get("action", "")) != "write_file":
		failures.append("executor_payload_from_tool_call: expected action=write_file")
	if payload1.get("execute_on_client", false) != true:
		failures.append("executor_payload_from_tool_call: expected execute_on_client=true")
	if str(payload1.get("path", "")) != "res://a.gd":
		failures.append("executor_payload_from_tool_call: expected path=res://a.gd")

	var tc2 := {
		"output": {
			"execute_on_client": true,
			"action": "run_scene",
			"scene_path": "res://x.tscn",
		}
	}
	var payload2 := GodotAIToolRunner.executor_payload_from_tool_call(tc2)
	if str(payload2.get("action", "")) != "run_scene":
		failures.append("executor_payload_from_tool_call: expected action=run_scene from output block")
	if payload2.get("execute_on_client", false) != true:
		failures.append("executor_payload_from_tool_call: expected execute_on_client=true from output block")

	var tc3 := {
		"output": {
			"execute_on_client": false,
			"action": "run_scene",
		},
		"tool_name": "write_file",
		"arguments": { "path": "res://a.gd", "content": "print(1)" },
	}
	var payload3 := GodotAIToolRunner.executor_payload_from_tool_call(tc3)
	if str(payload3.get("action", "")) != "write_file":
		failures.append("executor_payload_from_tool_call: expected fallback to tool_name mapping when output.execute_on_client=false")

	if failures.size() > 0:
		print("CONTRACT TESTS FAILED:")
		for f in failures:
			print("- " + f)
		get_tree().quit(1)
	else:
		print("CONTRACT TESTS PASSED")
		get_tree().quit(0)

