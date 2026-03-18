# Dev Log

## March 17, 2026

I am trying to refactor all of the Godot plugin to use MVC. I am frustrated because development velocity has slown to a crawl, every time LLM touches a .gd file, there are a million linter errors, and it doesn't understand how to lint.

I am trying to build a lint pipeline that works for GDscript. We were using .ps1 lint program, now we will try making a Task.

Fine tuning model V1 is training right now. I have set up tests so I can compare it's performance to GPT4.1-mini afterwards.

