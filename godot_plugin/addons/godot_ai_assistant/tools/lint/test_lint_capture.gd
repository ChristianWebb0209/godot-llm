@tool
extends RefCounted
class_name GodotAILintCaptureTest

## Tests for in-editor lint capture (Logger + reload). Run from plugin menu or Output.
## See CONTEXT.md or README for how to run.

const _TEST_DIR := "res://addons/godot_ai_assistant/tools/lint/_test_temp"
const _BAD_SCRIPT := "res://addons/godot_ai_assistant/tools/lint/_test_temp/bad.gd"
const _GOOD_SCRIPT := "res://addons/godot_ai_assistant/tools/lint/_test_temp/good.gd"

## Script content that will produce a parse error (unclosed string).
const _BAD_CONTENT := """extends RefCounted
func _ready() -> void:
	var x := "unclosed string
	pass
"""

## Valid GDScript.
const _GOOD_CONTENT := """extends RefCounted
func _ready() -> void:
	pass
"""


static func _ensure_test_dir() -> bool:
	var base := _TEST_DIR.get_base_dir()
	var da := DirAccess.open(base)
	if da == null:
		push_error("Lint test: could not open base dir: " + base)
		return false
	if not da.dir_exists("_test_temp"):
		var err := da.make_dir("_test_temp")
		if err != OK:
			push_error("Lint test: could not create _test_temp: " + str(err))
			return false
	return true


static func _write_file(path: String, content: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Lint test: could not write " + path)
		return false
	f.store_string(content)
	f.close()
	return true


static func _remove_test_files() -> void:
	var da := DirAccess.open(_TEST_DIR)
	if da != null:
		da.remove("bad.gd")
		da.remove("good.gd")
	var da_base := DirAccess.open(_TEST_DIR.get_base_dir())
	if da_base != null and da_base.dir_exists("_test_temp"):
		da_base.remove("_test_temp")


## Run all lint-capture tests. Returns true if all pass. Prints to Output.
static func run_all_tests() -> bool:
	print("[Lint capture test] Starting...")
	if not _ensure_test_dir():
		return false
	if not _write_file(_BAD_SCRIPT, _BAD_CONTENT):
		_remove_test_files()
		return false
	if not _write_file(_GOOD_SCRIPT, _GOOD_CONTENT):
		_remove_test_files()
		return false

	var passed := 0
	var failed := 0

	# Test 1: script with parse error -> we expect ok == false and non-empty output
	var res_bad := GodotAIServerLint.run_lint_local_only(_BAD_SCRIPT)
	if not res_bad.get("ok", true) and not (res_bad.get("output", "") as String).strip_edges().is_empty():
		passed += 1
		print("[Lint capture test] PASS: bad script reported errors: ", res_bad.get("output", ""))
	else:
		failed += 1
		push_error("[Lint capture test] FAIL: bad script should fail lint with message. got ok=%s output=%s" % [res_bad.get("ok"), res_bad.get("output", "")])

	# Test 2: valid script -> we expect ok == true and empty output
	var res_good := GodotAIServerLint.run_lint_local_only(_GOOD_SCRIPT)
	if res_good.get("ok", false) and (res_good.get("output", "") as String).strip_edges().is_empty():
		passed += 1
		print("[Lint capture test] PASS: good script passed lint.")
	else:
		failed += 1
		push_error("[Lint capture test] FAIL: good script should pass. got ok=%s output=%s" % [res_good.get("ok"), res_good.get("output", "")])

	_remove_test_files()

	if failed == 0:
		print("[Lint capture test] All %d tests passed." % passed)
		return true
	else:
		push_error("[Lint capture test] %d passed, %d failed." % [passed, failed])
		return false
