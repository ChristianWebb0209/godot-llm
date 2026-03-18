@tool
extends RefCounted
class_name GodotAIHttpRequestHandler

## Controller: handles backend HTTPRequest lifecycle (health check + non-streaming responses).

var _dock: GodotAIDock

func _init(dock: GodotAIDock) -> void:
	_dock = dock


func start_health_check() -> void:
	if not _dock.http_request:
		return
	var base: String = _dock.rag_service_url.strip_edges()
	if base.is_empty() or not base.begins_with("http"):
		_dock.clear_pending_http_kind()
		return
	var url: String = base + ("health" if base.ends_with("/") else "/health")
	# HTTPRequest requires an absolute URL.
	if url.is_empty() or not url.begins_with("http"):
		_dock.clear_pending_http_kind()
		return
	_dock.set_pending_http_kind(&"health")
	_dock.set_status("Checking backend...")
	var err := _dock.http_request.request(url)
	if err != OK:
		_dock.set_status("Failed to start health check.")
		_dock.clear_pending_http_kind()


func on_http_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	print("AI Assistant: HTTP request completed. result=", result, " code=", response_code)

	if result != HTTPRequest.RESULT_SUCCESS:
		var msg := "Request failed: %d" % result
		_dock.set_status(msg)
		_dock.append_error_to_chat(msg)
		_dock.clear_pending_http_kind()
		return

	if response_code < 200 or response_code >= 300:
		var msg := "HTTP error: %d" % response_code
		_dock.set_status(msg)
		_dock.append_error_to_chat(msg)
		_dock.clear_pending_http_kind()
		return

	var body_text: String = body.get_string_from_utf8()
	print("AI Assistant: response body: ", body_text)

	var json := JSON.new()
	var parse_result: int = json.parse(body_text)
	if parse_result != OK:
		var msg := "Failed to parse JSON response from backend."
		_dock.set_status(msg)
		_dock.append_error_to_chat(msg)
		_dock.clear_pending_http_kind()
		return

	var data := json.data
	if typeof(data) != TYPE_DICTIONARY:
		var msg := "Unexpected response format from backend."
		_dock.set_status(msg)
		_dock.append_error_to_chat(msg)
		_dock.clear_pending_http_kind()
		return

	if _dock.get_pending_http_kind() == &"health":
		_dock.handle_backend_health_response(data as Dictionary)
		_dock.clear_pending_http_kind()
		return

	if _dock.get_pending_http_kind() == &"query":
		_dock.clear_pending_http_kind()
		_dock.handle_backend_query_response(data as Dictionary)
		return

	_dock.clear_pending_http_kind()

