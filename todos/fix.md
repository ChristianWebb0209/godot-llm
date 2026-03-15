im concerned about the speeed of my create_file tool. it seems to take the llm forever just tom ake a simple file

That slowdown almost never comes from the file creation itself. Writing a file to disk takes milliseconds. The delay usually comes from the LLM reasoning loop around the tool, which is where things like Cursor spend most of their time.

What’s happening is usually some version of this:

LLM
→ plan change
→ generate file contents
→ format tool call
→ send tool call
server
→ write file
→ return result
LLM
→ verify result
→ continue reasoning

The expensive step is the model generating the entire file content in the tool call. If the file is even moderately long, the model may spend seconds generating tokens.

There are a few tricks that dramatically improve speed.

The first is separating file creation from file writing.

Instead of this tool:

create_file(path, content)

split it into:

create_file(path)
write_file(path, content)

Why this helps: the AI can instantly create the file, then stream or incrementally write content.

It also mirrors how developers actually work.

Another improvement is diff-based editing instead of full rewrites.

Large models are terrible at rewriting whole files efficiently. Systems like Cursor rarely send full files; they send patches.

Example:

apply_patch(path, diff)

Diffs are dramatically smaller than full files.

Example patch:

+ func jump():
+     velocity.y = -jump_force

Much faster for the model to generate.

Another huge speed win is template tools.

Right now your AI probably generates boilerplate like this every time:

extends CharacterBody2D

func _physics_process(delta):
    pass

Instead, create tools like:

create_script(path, template="character_2d")

Your backend fills the template instantly.

The AI only writes the interesting logic.

Cursor does this constantly behind the scenes.

Another subtle performance killer is verification loops.

Some systems automatically do this:

create_file
→ read_file
→ verify content

That doubles the roundtrips.

You can avoid this by returning the written content in the tool response so the model doesn’t need to read it again.

Another trick that helps agents a lot is file preview context.

If the model knows the file is new, it doesn’t need to inspect anything.

Example context:

File does not exist yet.
You are creating a new script.

That removes a lot of unnecessary exploration.

The deeper principle here is something that surprised many teams building AI coding tools.

The slow part isn’t IO.
The slow part is token generation.

Writing 200 lines of code requires the model to emit hundreds of tokens, and that takes time.

So most production systems try to minimize tokens in tool calls.

That’s why they rely heavily on:

patches

templates

incremental edits

structured operations

instead of full file generation.

For a Godot assistant specifically, a good toolset might look like:

create_script(path, base_type)
append_to_file(path, content)
apply_patch(path, diff)
create_scene(name)
add_node(scene, node_type)

Notice how many of those tools encode intent instead of raw text.

The more intent your tools capture, the less code the model has to generate.

There’s a funny paradox here: the smarter your tool layer becomes, the less code the AI needs to write. And the less code it writes, the faster the system feels.

That’s one of the hidden design secrets behind tools like Cursor. They don’t just let the AI type code—they quietly build a layer of high-level actions so the AI can move the project forward with far fewer tokens.