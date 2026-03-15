@tool
extends RefCounted
class_name GodotAIBackendClient

## HTTP client for RAG backend: URL parsing, JSON query, streaming POST, fire-and-forget POST.

## Parse URL like http://host:port/path into { host, port, path, use_tls }.
static func parse_url(endpoint: String) -> Dictionary:
	var host := ""
	var port := 80
	var use_tls := false
	var path := "/"

	var scheme_split := endpoint.split("://")
	var remainder := endpoint
	if scheme_split.size() == 2:
		var scheme := scheme_split[0]
		remainder = scheme_split[1]
		if scheme == "https":
			use_tls = true
			port = 443
		else:
			use_tls = false
			port = 80

	var first_slash := remainder.find("/")
	var host_port := remainder if first_slash == -1 else remainder.substr(0, first_slash)
	if first_slash >= 0:
		path = remainder.substr(first_slash)

	var colon_index := host_port.find(":")
	if colon_index == -1:
		host = host_port
	else:
		host = host_port.substr(0, colon_index)
		port = int(host_port.substr(colon_index + 1))

	return {"host": host, "port": port, "path": path, "use_tls": use_tls}


## Perform HTTP request and return parsed JSON (Dictionary or null). Async.
static func query_json(p_node: Node, endpoint: String, method: int, body: String) -> Variant:
	var parsed = parse_url(endpoint)
	var host: String = parsed.get("host", "")
	var port: int = int(parsed.get("port", 80))
	var path: String = parsed.get("path", "/")
	var use_tls: bool = parsed.get("use_tls", false)

	var client := HTTPClient.new()
	var tls_options: TLSOptions = null
	if use_tls:
		tls_options = TLSOptions.client()

	var err := client.connect_to_host(host, port, tls_options)
	if err != OK:
		return null

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await p_node.get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return null

	var headers := PackedStringArray(["Content-Type: application/json"])
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Length: %d" % body.to_utf8_buffer().size())
		client.request(method, path, headers, body)
	else:
		client.request(method, path, headers, "")

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await p_node.get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_BODY:
		return null

	var response_bytes := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			response_bytes.append_array(chunk)
		await p_node.get_tree().process_frame

	var body_text := response_bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(body_text) != OK:
		return null
	return json.data


## Stream POST: call on_chunk(delta: String) for each chunk, then on_done(full_text: String, error_message: String). Async.
## error_message is non-empty only on failure. If cancel_check (Callable with no args returning bool) is valid and returns true, stop early and call on_done with current text and "".
static func stream_post(
	p_node: Node,
	endpoint: String,
	body: String,
	on_chunk: Callable,
	on_done: Callable,
	cancel_check: Callable = Callable()
) -> void:
	var tree := p_node.get_tree() if p_node else null
	if not tree:
		var msg := "Stream failed: node not in scene tree."
		push_error("AI Assistant: " + msg)
		on_done.call("", msg)
		return
	var parsed = parse_url(endpoint)
	var host: String = parsed.get("host", "")
	var port: int = int(parsed.get("port", 80))
	var path: String = parsed.get("path", "/")
	var use_tls: bool = parsed.get("use_tls", false)
	if host.is_empty():
		var msg := "Stream failed: invalid URL (empty host). Check backend URL in settings."
		push_error("AI Assistant: " + msg)
		on_done.call("", msg)
		return

	var client := HTTPClient.new()
	var tls_options: TLSOptions = null
	if use_tls:
		tls_options = TLSOptions.client()

	var err := client.connect_to_host(host, port, tls_options)
	if err != OK:
		var msg := "Stream failed: could not connect to %s:%d (error %d). Is the backend running?" % [host, port, err]
		push_error("AI Assistant: " + msg)
		on_done.call("", msg)
		return

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		if cancel_check.is_valid() and cancel_check.call():
			on_done.call("", "")
			return
		client.poll()
		await tree.process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		var msg := "Stream failed: connection failed after connect. Is the backend running? (If using --reload, try running without it.)"
		push_error("AI Assistant: " + msg)
		on_done.call("", msg)
		return

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Content-Length: %d" % body.to_utf8_buffer().size(),
	])
	client.request(HTTPClient.METHOD_POST, path, headers, body)

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if cancel_check.is_valid() and cancel_check.call():
			on_done.call("", "")
			return
		client.poll()
		await tree.process_frame

	if client.get_status() != HTTPClient.STATUS_BODY:
		var msg := "Stream failed: server returned HTTP status %d. Server may have restarted or returned an error." % client.get_status()
		push_error("AI Assistant: " + msg)
		on_done.call("", msg)
		return

	var full_text := ""
	while client.get_status() == HTTPClient.STATUS_BODY:
		if cancel_check.is_valid() and cancel_check.call():
			on_done.call(full_text, "")
			return
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			await tree.process_frame
			continue
		var delta := chunk.get_string_from_utf8()
		if delta.is_empty():
			await tree.process_frame
			continue
		full_text += delta
		if on_chunk.is_valid():
			on_chunk.call(delta)
		await tree.process_frame

	on_done.call(full_text, "")


## Fire-and-forget POST: send body and consume response without returning. Async.
static func post_fire_and_forget(p_node: Node, endpoint: String, body: String) -> void:
	var parsed = parse_url(endpoint)
	var host: String = parsed.get("host", "")
	var port: int = int(parsed.get("port", 80))
	var path: String = parsed.get("path", "/")

	var client := HTTPClient.new()
	var err := client.connect_to_host(host, port)
	if err != OK:
		return

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await p_node.get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Content-Length: %d" % body.to_utf8_buffer().size()
	])
	client.request(HTTPClient.METHOD_POST, path, headers, body)

	while client.get_status() in [HTTPClient.STATUS_REQUESTING, HTTPClient.STATUS_BODY]:
		client.poll()
		client.read_response_body_chunk()
		await p_node.get_tree().process_frame
