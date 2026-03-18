
# Rebuilding tool_usage.jsonl dataset.

## Why?

This one has countless issues: data isnt formatted in tool_call tags, we don't have negative examples, we don't have a set of short, concise examples that are short prompts with one tool call.

## Solution

For now, all the old scripts are moved to old/ in case I need to reference them for this, but I will likely delete them later.

I will use the following prompt to rebuild scripts and rebuild the dataset again using OpenAI calls.
