---
name: bootstrap
description: Propose an engine-standard project starting point, with explicit engine selection and approval before creation
---
1. Ask the user to select Unreal, Godot, Playdate, or Unity; never select solely from installed software or detected files. Ask engine version if needed.
2. If Playdate, ask whether to use standard Playdate SDK/Lua or custom Corgo Engine. Never assume Corgo APIs; inspect provided source/docs first.
3. Ask whether this is a new project or an existing one. Inspect existing files read-only.
4. Research official templates and established conventions; distinguish documented standards from preferences. Favor minimal viable architecture over speculative frameworks.
5. Evaluate relevant built-in tools, plugins, external editors, and alternate languages using /tool-eval when appropriate.
6. Present folder tree, key components, test/build workflow, risks, alternatives, and proposed ARCHITECTURE.md / DECISIONS.md entries.
7. Request explicit approval before creating or modifying any project files. Reconfirm for material scope changes.
8. After approval, implement only approved scope, validate with actual available tools, and update architecture/state documents. Never claim validation without execution.
