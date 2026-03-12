@tool
extends Control
class_name GodotAIDock

@onready var prompt_text_edit: TextEdit = $"VBox/IOContainer/PromptTextEdit"
@onready var ask_button: Button = $"VBox/Controls/AskButton"
@onready var copy_button: Button = $"VBox/Controls/CopyButton"
@onready var output_text_edit: RichTextLabel = $"VBox/IOContainer/OutputText"
@onready var status_label: Label = $"VBox/Controls/StatusLabel"
@onready var http_request: HTTPRequest = $HTTPRequest

var rag_service_url: String = "http://127.0.0.1:8000"


func _ready() -> void:
	print("AI Assistant: _ready called on dock")
	if ask_button:
		ask_button.pressed.connect(_on_ask_button_pressed)
	else:
		print("AI Assistant: ask_button is null")

	if copy_button:
		copy_button.pressed.connect(_on_copy_button_pressed)
	else:
		print("AI Assistant: copy_button is null")

	if http_request:
		http_request.request_completed.connect(_on_http_request_completed)
	else:
		print("AI Assistant: http_request is null")


func _on_ask_button_pressed() -> void:
	print("AI Assistant: Ask button pressed")
	var question: String = prompt_text_edit.text.strip_edges()
	if question.is_empty():
		status_label.text = "Please enter a question."
		return

	status_label.text = "Sending request to RAG service..."
	output_text_edit.clear()

	var active_language := "gdscript"
	# In the future, this can be inferred from the active script in the editor.
	var payload := {
		"question": question,
		"context": {
			"engine_version": Engine.get_version_info().get("string"),
			"language": active_language,
			"selected_node_type": "",
			"current_script": "",
			"extra": {}
		},
		"top_k": 5
	}

	var json_body: String = JSON.stringify(payload)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var endpoint: String = "%s/query" % rag_service_url

	var err: int = http_request.request(endpoint, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		status_label.text = "HTTP request error: %s" % error_string(err)
		print("AI Assistant: HTTP request error: ", err, " ", error_string(err))
	else:
		print("AI Assistant: request sent to ", endpoint)


func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	print("AI Assistant: HTTP request completed. result=", result, " code=", response_code)

	if result != HTTPRequest.RESULT_SUCCESS:
		status_label.text = "Request failed: %d" % result
		return

	if response_code < 200 or response_code >= 300:
		status_label.text = "HTTP error: %d" % response_code
		return

	var body_text: String = body.get_string_from_utf8()
	print("AI Assistant: response body: ", body_text)

	var json := JSON.new()
	var parse_result: int = json.parse(body_text)
	if parse_result != OK:
		status_label.text = "Failed to parse JSON response."
		return

	var data := json.data
	if typeof(data) != TYPE_DICTIONARY:
		status_label.text = "Unexpected response format."
		return

	var answer: String = data.get("answer", "")
	var snippets: Array = data.get("snippets", [])

	output_text_edit.clear()
	output_text_edit.append_text(str(answer))

	if snippets is Array and snippets.size() > 0:
		output_text_edit.add_newline()
		output_text_edit.push_bold()
		output_text_edit.add_text("\n\nSnippets:\n")
		output_text_edit.pop()
		for snippet in snippets:
			if typeof(snippet) == TYPE_DICTIONARY:
				var preview: String = snippet.get("text_preview", "")
				var source_path: String = snippet.get("source_path", "")
				output_text_edit.add_text("\nSource: %s\n" % source_path)
				output_text_edit.add_text("%s\n" % preview)

	status_label.text = "Response received."


func _on_copy_button_pressed() -> void:
	if not output_text_edit:
		return
	var text_to_copy := output_text_edit.get_parsed_text()
	if text_to_copy.is_empty():
		status_label.text = "Nothing to copy."
		return
	DisplayServer.clipboard_set(text_to_copy)
	status_label.text = "Copied answer to clipboard."
