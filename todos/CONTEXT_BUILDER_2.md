
Todo:
Recency scoring / working set: can be layered on top next by pulling recent edited files from SQLite and including small summaries/diffs as candidates.
True compression (summaries) vs truncation: currently we trim; next step is add a “summarize block” fallback when trimming would remove too much.

Probably already done but still verify:
Structural proximity / import graph walking: needs a project-aware resolver (we can add later once we decide how to access files on disk safely from the editor).



Below is the past task. probably ignore unelss you need context.

We need to expand and chagne our context builder. For starters, when building context, the currently selected file should be strongly considered. it should depend on what the godot editor is focused on. so look at either which scene or file is selected, and make sure that is used (this may involve looking at the script editor and which script is open, or just which scene).

Heres some other rules for building a good context builder. Please implement them as well as you can with our current system, and reoprt about successes.

system instructions → current task → active file → errors → retrieved knowledge → optional extras.

Each block has a token budget. When the prompt grows too big, the system trims the least valuable blocks first rather than randomly cutting text. The goal is stability: the model should always see the same kinds of information in roughly the same order.

The most reliable heuristic is locality first. The current file or function almost always matters more than anything else in the project. So many coding assistants start with something like:

current file → error message → user instruction.

That tiny bundle solves a surprising percentage of problems. If the model still struggles, the context builder expands outward.

The next heuristic is structural proximity. Code that the current file imports or references tends to matter more than distant files. A simple strategy is: include the files that are directly imported, then maybe one level deeper if needed. That mimics how human programmers reason.

Another common rule is retrieval over dumping. Instead of sending lots of project files, run a search first. Your vector database (for you, Chroma) returns the most semantically similar pieces of knowledge. Usually only the top three to five chunks are needed. More than that often just dilutes the signal.

A good mental model is that every piece of context has a relevance score. Context builders often combine several signals:

semantic similarity
recency of use
structural dependency
error relevance.

Recency is particularly useful in interactive coding sessions. Files the AI edited recently often stay relevant for a while. Some systems give each item a decaying score: every time it’s referenced, its score rises; over time the score slowly falls. When the prompt needs trimming, the lowest scores get removed.

Another trick is sliding windows. Instead of sending an entire file, only send the region around the active code. For example, 50 lines above and below the function being edited. That dramatically reduces tokens while preserving useful context.

About the question of whether new items should enter context immediately or only after repeated reference: most systems include them once, but demote them quickly if they’re not used again. Think of it as “trial inclusion.” If the model references them or they appear in subsequent retrieval results, they stay. Otherwise they fade out.

Context builders also benefit from summaries instead of raw text. Large files or long conversations get compressed into short descriptions. That might look like a short note such as “EnemyAI.gd handles enemy movement and emits enemy_died signal.” That summary costs maybe twenty tokens instead of hundreds.

Another widely used rule is error-first prioritization. When debugging, the lint error or stack trace becomes a top-ranked context item. Code assistants that ignore the error message tend to wander.

There’s also the idea of progressive context expansion. The system starts with minimal context. If the answer fails or the lint error persists, the builder adds more context in the next attempt. This keeps prompts small most of the time while still allowing deeper reasoning when needed.

In many systems the context builder maintains a small working set, maybe five to ten items. Each item might be a file snippet, documentation chunk, or previous fix example. When a new candidate arrives, the builder calculates its relevance score and decides whether it replaces something in the working set.

A surprising but important heuristic is ordering matters. Models tend to pay more attention to the earliest blocks. So instructions and the primary code context usually go first, with auxiliary knowledge later.

One more rule worth mentioning is diversity filtering. If the retrieval system returns five nearly identical chunks, keep one and discard the rest. Redundant context wastes tokens without adding information.