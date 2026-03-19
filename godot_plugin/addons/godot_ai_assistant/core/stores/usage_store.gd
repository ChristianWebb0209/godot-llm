@tool
extends RefCounted
class_name GodotAIUsageStore

## Client-side token usage + cost tracking.
##
## Stored under:
## - user://godot_ai_assistant/usage/usage.json
##
## Note: backend currently reports token usage as (prompt_tokens, completion_tokens).
## In the client we primarily have context/estimated prompt token info, so completion
## tokens may be 0 (approximate totals).

const ROOT_DIR := "user://godot_ai_assistant"
const STORE_PATH := ROOT_DIR + "/usage/usage.json"

const MODEL_PRICING: Dictionary = {
	"gpt-4.1-mini": {"input_per_1k": 0.0004, "output_per_1k": 0.0016},
}

var by_model: Dictionary = {} # model -> { prompt_tokens:int, completion_tokens:int, updated_unix:int }

static func _now_unix() -> int:
	return int(Time.get_unix_time_from_system())

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	if txt.strip_edges().is_empty():
		return null
	var j := JSON.new()
	if j.parse(txt) != OK:
		return null
	return j.data

static func _write_json_atomic(path: String, data: Variant) -> void:
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		DirAccess.make_dir_recursive_absolute(dir_path)
	var tmp_path := "%s.tmp_%d" % [path, Time.get_unix_time_from_system()]
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
	f.close()
	# Best-effort atomic swap (Godot user:// maps to a real dir).
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp_path, path)

func load_from_disk() -> void:
	var d := _read_json(STORE_PATH)
	if typeof(d) != TYPE_DICTIONARY:
		by_model = {}
		return
	by_model = d.get("by_model", {}) if d.get("by_model", {}) is Dictionary else {}

func save_to_disk() -> void:
	var d := {"by_model": by_model}
	_write_json_atomic(STORE_PATH, d)

func record_usage(model: String, prompt_tokens: int, completion_tokens: int = 0) -> void:
	var m := str(model).strip_edges()
	if m.is_empty():
		m = "unknown"
	var now := _now_unix()
	var cur := by_model.get(m, null)
	if typeof(cur) != TYPE_DICTIONARY:
		cur = {"prompt_tokens": 0, "completion_tokens": 0, "updated_unix": now}
	cur["prompt_tokens"] = int(cur.get("prompt_tokens", 0)) + max(0, int(prompt_tokens))
	cur["completion_tokens"] = int(cur.get("completion_tokens", 0)) + max(0, int(completion_tokens))
	cur["updated_unix"] = now
	by_model[m] = cur
	save_to_disk()

func get_usage_totals() -> Dictionary:
	var total_prompt_tokens := 0
	var total_completion_tokens := 0
	var total_tokens := 0
	var by_m: Dictionary = {}
	for model in by_model.keys():
		var rec := by_model.get(model, {})
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var pt := int(rec.get("prompt_tokens", 0))
		var ct := int(rec.get("completion_tokens", 0))
		by_m[model] = {"prompt_tokens": pt, "completion_tokens": ct}
		total_prompt_tokens += pt
		total_completion_tokens += ct
	total_tokens = total_prompt_tokens + total_completion_tokens

	var estimated_cost_usd := 0.0
	for model in by_m.keys():
		var pt := int(by_m[model].get("prompt_tokens", 0))
		var ct := int(by_m[model].get("completion_tokens", 0))
		estimated_cost_usd += _estimate_cost_usd(model, pt, ct)

	# Manual rounding to 4 decimals (linter doesn't expose stepify() here).
	var rounded_cost := float(int(estimated_cost_usd * 10000.0 + 0.5)) / 10000.0

	return {
		"total_prompt_tokens": total_prompt_tokens,
		"total_completion_tokens": total_completion_tokens,
		"total_tokens": total_tokens,
		"estimated_cost_usd": rounded_cost,
		"by_model": by_m,
	}

static func _estimate_cost_usd(model: String, prompt_tokens: int, completion_tokens: int) -> float:
	var pricing: Dictionary = MODEL_PRICING.get(model, {})
	if pricing.is_empty():
		return 0.0
	var input_per_1k := float(pricing.get("input_per_1k", 0.0))
	var output_per_1k := float(pricing.get("output_per_1k", 0.0))
	var input_cost := (float(prompt_tokens) / 1000.0) * input_per_1k
	var output_cost := (float(completion_tokens) / 1000.0) * output_per_1k
	return input_cost + output_cost

