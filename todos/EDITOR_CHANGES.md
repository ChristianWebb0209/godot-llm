# we need to brainstorm the godot editor changes we wish to make for our program to be usable.

## we should probably use custom inspectors and editors.

Godot allows plugins to override how specific resources or nodes are displayed.

For example, you can write:

EditorInspectorPlugin

which lets you modify how the inspector panel displays node properties.

This is powerful if you want AI-related information to appear alongside node properties.

Example idea:

Inspector Panel

Position: (0,0)
Rotation: 0
Scale: (1,1)

AI Info:
Created by agent #12
Modified 3 minutes ago

No engine modification required.

-----
1. Script editor indicators

This is the first and most important.

Files touched by the AI should visually change.

For example:

green → new file created by AI
yellow → file modified by AI
red → AI attempted change but lint failed

This can appear:

• in the script tab bar
• in the file tree

These are the two places developers constantly look.

2. Diff preview panel

When the AI edits code, show a side-by-side diff viewer.

Think GitHub-style:

old code | new code

Users can accept or reject the change.

This dramatically increases trust.

Your agent manager could open a “pending changes” panel showing diffs.

3. AI change timeline

This becomes your debugging memory.

A simple vertical list:

[10:41] Fixed lint error in player.gd
[10:39] Added signal connection
[10:37] Created enemy_ai.gd

Clicking an item opens the diff.

That turns your system into something like a mini Git history for AI actions.

4. Scene tree indicators

Godot’s scene tree is extremely important.

If the AI changes nodes, highlight them.

Example:

• green node → AI created
• yellow node → AI modified properties

This makes scene edits obvious.