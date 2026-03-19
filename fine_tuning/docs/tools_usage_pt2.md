
# Rebuilding tool_usage.jsonl dataset.

## Why?

This one has countless issues: data isnt formatted in tool_call tags, we don't have negative examples, we don't have a set of short, concise examples that are short prompts with one tool call.

## Solution

For now, the legacy scripts are moved to `fine_tuning/scripts/legacy/` in case I need to reference them for this, but I may delete them later.

I will use the following prompt to rebuild scripts and rebuild the dataset again using OpenAI calls.
