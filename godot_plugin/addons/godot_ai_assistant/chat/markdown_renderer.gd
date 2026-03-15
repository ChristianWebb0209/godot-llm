extends Resource

class_name GodotAIMarkdownRenderer

const _LOG_PREFIX := "[AI Assistant] "


func _split_lines_preserve_newlines(text: String) -> Array:
	var lines: Array = []
	var current := ""
	for ch in text:
		current += ch
		if ch == "\n":
			lines.append(current)
			current = ""
	if current != "":
		lines.append(current)
	return lines


func markdown_to_bbcode(md: String) -> String:
	var lines: Array = _split_lines_preserve_newlines(md)
	var out_lines: Array = []
	var in_code_block := false

	for raw_line in lines:
		var line: String = String(raw_line).rstrip("\r\n")

		# Fenced code blocks ```...```
		if line.begins_with("```"):
			if not in_code_block:
				in_code_block = true
				out_lines.append("[code]")
			else:
				in_code_block = false
				out_lines.append("[/code]")
			continue

		if in_code_block:
			# Escape [ ] so BBCode (RichTextLabel) doesn't parse them as tags
			out_lines.append(line.replace("[", "[lb]").replace("]", "[rb]"))
			continue

		# Headings
		if line.begins_with("### "):
			out_lines.append("[b]" + line.substr(4) + "[/b]")
			continue
		if line.begins_with("## "):
			out_lines.append("[b]" + line.substr(3) + "[/b]")
			continue
		if line.begins_with("# "):
			out_lines.append("[b]" + line.substr(2) + "[/b]")
			continue

		# Lists
		if line.begins_with("- "):
			out_lines.append("• " + line.substr(2))
			continue

		# Inline code: `code`
		var processed := ""
		var i := 0
		var in_inline_code := false
		while i < line.length():
			var c: String = line[i]
			if c == "`":
				in_inline_code = not in_inline_code
				if in_inline_code:
					processed += "[code]"
				else:
					processed += "[/code]"
				i += 1
				continue
			processed += c
			i += 1

		# Bold **text**
		processed = _replace_delimited(processed, "**", "[b]", "[/b]")
		# Italic *text*
		processed = _replace_delimited(processed, "*", "[i]", "[/i]")

		out_lines.append(processed)

	var result_bb := "\n".join(out_lines)
	return result_bb


func _replace_delimited(text: String, marker: String, open_tag: String, close_tag: String) -> String:
	var result := ""
	var i := 0
	var open := true
	while i < text.length():
		if text.substr(i, marker.length()) == marker:
			if open:
				result += open_tag
			else:
				result += close_tag
			open = not open
			i += marker.length()
		else:
			result += text[i]
			i += 1
	return result
