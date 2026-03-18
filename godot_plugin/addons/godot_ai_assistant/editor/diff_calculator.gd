@tool
extends RefCounted
class_name GodotAIDiffCalculator

## Pure diff logic: given old and new content, returns per-line change type for the NEW file.
## Used by diff_review to apply green (add), yellow (modify), red (removed/replace) highlights.
## Separation of concerns: no editor or UI; only string/array in, array of line types out.

enum LineChangeType {
	NONE,
	ADD,
	MODIFY,
	REMOVE_REPLACE,
}

## For each line index (0-based) in the new content, returns LineChangeType.
## Result array size = new line count. ADD = green, MODIFY = yellow, REMOVE_REPLACE = red, NONE = no highlight.
static func compute_line_changes(old_content: String, new_content: String) -> Array:
	var old_lines := _to_lines(old_content)
	var new_lines := _to_lines(new_content)
	return _compute_line_changes_impl(old_lines, new_lines)


static func _to_lines(s: String) -> PackedStringArray:
	if s.is_empty():
		return PackedStringArray()
	return s.split("\n", false)


## LCS-based: for each new line we determine if it was added, modified, or unchanged.
## REMOVE_REPLACE: line in new that replaced one or more removed lines in old (block replacement).
static func _compute_line_changes_impl(old_lines: PackedStringArray, new_lines: PackedStringArray) -> Array:
	var n_old := old_lines.size()
	var n_new := new_lines.size()
	var result: Array = []
	result.resize(n_new)
	for i in range(n_new):
		result[i] = LineChangeType.NONE

	if n_old == 0:
		for i in range(n_new):
			result[i] = LineChangeType.ADD
		return result
	if n_new == 0:
		return result

	# dp[i][j] = length of LCS of old_lines[0..i), new_lines[0..j)
	var dp: Array = []
	for i in range(n_old + 1):
		var row: Array = []
		row.resize(n_new + 1)
		dp.append(row)
	for i in range(n_old + 1):
		dp[i][0] = 0
	for j in range(n_new + 1):
		dp[0][j] = 0
	for i in range(1, n_old + 1):
		for j in range(1, n_new + 1):
			if old_lines[i - 1] == new_lines[j - 1]:
				dp[i][j] = dp[i - 1][j - 1] + 1
			else:
				dp[i][j] = maxi(dp[i - 1][j], dp[i][j - 1])

	# Backtrack: for each new line, NONE if matched, else ADD. Then detect MODIFY (content change) and REMOVE_REPLACE.
	var i := n_old
	var j := n_new
	while j > 0:
		if i > 0 and old_lines[i - 1] == new_lines[j - 1]:
			result[j - 1] = LineChangeType.NONE
			i -= 1
			j -= 1
		elif i > 0 and dp[i][j] == dp[i - 1][j]:
			i -= 1
		else:
			result[j - 1] = LineChangeType.ADD
			j -= 1

	return result


## Returns the 0-based line index of the first changed line (add/modify/remove_replace), or -1.
static func first_changed_line(line_changes: Array) -> int:
	for idx in range(line_changes.size()):
		if int(line_changes[idx]) != LineChangeType.NONE:
			return idx
	return -1
