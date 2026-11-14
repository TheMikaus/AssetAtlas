# Unity / C#
- Read `ProjectSettings/ProjectVersion.txt`, package manifest, and assembly definitions before proposing changes.
- Inspect existing MonoBehaviours, ScriptableObjects, prefabs, scenes, and event architecture.
- Preserve `.meta` GUIDs and serialized field compatibility; avoid changing assets through text editing unless safe and approved.
- Consider lifecycle ordering, allocations/GC, physics timing, and main-thread constraints.
- Propose EditMode/PlayMode tests and batchmode builds appropriate to the installed version; distinguish test results from actual in-editor/device validation.
- Ask approval before editor/batchmode operations that write Library or other generated state.
