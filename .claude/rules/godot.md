# Godot (GDScript / C#)
- Read `project.godot` to identify Godot version, renderer, autoloads, plugins, and main scene.
- Inspect existing scenes, nodes, signals, groups, resources, and script conventions before changes.
- Preserve scene/resource UIDs and references; treat `.tscn`, `.tres`, `.uid`, and import metadata carefully.
- Prefer typed GDScript where project conventions support it; for C#, verify .NET-enabled Godot and solution setup.
- For gameplay bugs, inspect node lifecycle (`_enter_tree`, `_ready`, `_process`, `_physics_process`), signal connections, and physics/input timing.
- Propose relevant headless editor parse/import checks, GDScript/C# tests, scene smoke tests, and export validation; verify actual CLI flags against installed version.
- Headless imports, builds, and tests may write `.godot/` or other files: require approval first.
- Never claim that a headless parse proves rendered gameplay or input behavior.
