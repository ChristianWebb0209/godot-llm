A clean design would look like this.

First, the top-level edit event:

{
  "edit_id": "uuid",
  "timestamp": "...",
  "actor": "ai",
  "trigger": "lint_fix",
  "prompt_hash": "...",
  "changes": [ ... ]
}

This represents a single AI action.

Inside that event you store file changes.

{
  "file_path": "addons/godot_ai_assistant/ai_dock.gd",
  "change_type": "modify",
  "diff": "...",
  "old_hash": "...",
  "new_hash": "..."
}

The diff is usually stored in unified diff format, which is the same format Git uses.

Example:

@@ -10,7 +10,7 @@
-func _ready():
-    velocity = move_and_slide(velocity)
+func _ready():
+    move_and_slide()

That format is incredibly powerful because:

• small
• human readable
• reversible
• compatible with existing tooling

It’s basically the lingua franca of code changes.

A full "file change" object usually contains a few more useful fields:

file_change
  file_path
  change_type
  diff
  old_hash
  new_hash
  lines_added
  lines_removed

Hashes help detect corruption or merge issues.

Now here's where things get interesting for your system.

Since you're building an AI learning loop, each edit should also store context metadata.

Something like:

ai_context
  prompt
  retrieved_chunks
  lint_errors_before
  lint_errors_after

This lets you reconstruct why the change happened.

Example record:

AI Edit
  reason: fix lint error
  error: "Invalid call to move_and_slide"
  retrieved_examples: [id_12, id_54]
  diff: ...

That turns your history into a training dataset for debugging.

Now about storage.

You don't want just a vector DB.

A good architecture is:

Postgres / SQLite
    edit history
    file changes
    lint fixes

Vector DB
    embeddings of:
        diffs
        error explanations
        fix summaries

Vector search helps answer questions like:

"have we fixed this error before?"

But relational storage is the source of truth.

Another trick used in some AI coding systems is semantic summaries of edits.

After a change, ask the model:

Summarize this code change in one sentence.

Example:

"Removed velocity argument from move_and_slide because CharacterBody2D stores velocity internally."

Store that alongside the diff.

That dramatically improves vector retrieval later.

Your system will eventually accumulate things like:

edit #238
error: invalid signal connection
fix: connect("pressed", self, "_on_pressed")

edit #417
error: missing await
fix: await get_tree().process_frame

At that point your assistant starts recognizing patterns and fixing errors faster.

One more idea worth considering.

Store multi-file edits as a single atomic event.

For example:

edit_event
  changes:
    player.gd
    enemy.gd
    ai_manager.gd

This preserves the intent of a refactor.