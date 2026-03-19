# Composer Versions & Notes

## v1 (current baseline before v2 changes)

### What we built
Godot Composer (fine-tuned) is accessed via the server endpoint `POST /composer/query` and is expected to return structured editor actions as `tool_calls`.

### v1 Contract / Implementation Issues
1. **Output parsing mismatch**
   - Composer runtime (in `rag_service/app/main.py`) originally parsed tool calls by looking for a **JSON array** at the end of the assistant message.
   - Many of the training examples (and/or tool example generators) used **XML tool-call blocks** like:
     - `<tool_call>{"name": "...", "arguments": {...}}</tool_call>`
   - When the model emitted XML but the runtime expected a JSON array, `tool_calls` became empty.

2. **Behavioral pollution (too many “no tool” outcomes)**
   - Training included lots of examples where tools were not required (conceptual questions, ambiguous prompts that lead to asking, etc.).
   - The model learned that returning “ask/options/explain” was an acceptable fallback.
   - In practice, most Composer samples produced `tool_calls: []`.

3. **`__OPTIONS__` / option-click flow added complexity**
   - The shared prompt and behavior around options/clarifying questions added formatting and behavior branching that wasn’t worth the cost once we introduced an explicit agent/ask mode for v2.

### Symptom summary
- Composer frequently returned helpful text but **did not produce tool calls**
- Only one or a very small subset of responses showed tool calls with usable structure.

## v2 (planned/implemented contract changes)

### What we changed in v2
1. **Explicit mode per request**
   - Request includes `composer_mode` set to:
     - `"agent"` (must emit tool calls)
     - `"ask"` (must ask exactly one question, must not call tools)

2. **Remove `__OPTIONS__` from Composer v2**
   - No option-click blocks for Composer v2.

3. **Parse XML tool-call blocks**
   - Runtime parsing was updated to extract `<tool_call>...</tool_call>` blocks and parse their inner JSON.

4. **Bias toward tool calls**
   - Dataset mix target: **80% agent / 20% ask**.

### Training dataset work
- Build Composer v2 datasets via:
  - translating existing tool datasets into AGENT-mode records
  - generating ASK-mode records (single-question only, no tool blocks)
  - generating additional AGENT-mode tool blocks at scale
  - validating + mixing deterministically (to avoid “pollution” drift)

