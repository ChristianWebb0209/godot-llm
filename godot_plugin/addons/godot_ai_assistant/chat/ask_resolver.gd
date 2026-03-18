@tool
extends RefCounted
class_name GodotAIAskResolver

## Parses assistant message text for the "ask with options" format from the backend.
## When the AI asks the user to choose, it can end the message with:
##   __OPTIONS__
##   - Option A
##   - Option B
##   __END_OPTIONS__
## This resolver extracts display text (with block removed) and the list of options for the UI.

const MARKER_OPTIONS := "__OPTIONS__"
const MARKER_END := "__END_OPTIONS__"

## Result: display_text = message with options block stripped; options = list of strings or empty.
static func resolve(raw_text: String) -> Dictionary:
	var out := {"display_text": "", "options": [], "has_options": false}
	if raw_text.is_empty():
		return out
	var opts_start := raw_text.find(MARKER_OPTIONS)
	if opts_start < 0:
		out["display_text"] = raw_text.strip_edges()
		return out
	var opts_end := raw_text.find(MARKER_END, opts_start)
	if opts_end < 0:
		out["display_text"] = raw_text.strip_edges()
		return out
	# Build display text: everything before __OPTIONS__ and after __END_OPTIONS__, trimmed.
	var before := raw_text.substr(0, opts_start).strip_edges()
	var after := raw_text.substr(opts_end + MARKER_END.length()).strip_edges()
	var parts: PackedStringArray = []
	if not before.is_empty():
		parts.append(before)
	if not after.is_empty():
		parts.append(after)
	out["display_text"] = "\n\n".join(parts)
	# Parse options: lines between the two markers; each line "- label" or "* label".
	var block_len := opts_end - opts_start - MARKER_OPTIONS.length()
	var block := raw_text.substr(opts_start + MARKER_OPTIONS.length(), block_len)
	var options: Array[String] = []
	for line in block.split("\n"):
		line = line.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("- "):
			options.append(line.substr(2).strip_edges())
		elif line.begins_with("* "):
			options.append(line.substr(2).strip_edges())
	if options.size() > 0:
		out["has_options"] = true
		out["options"] = options
	return out
