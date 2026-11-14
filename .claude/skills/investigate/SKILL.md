---
name: investigate
description: Investigate a gameplay, engine, build, or tooling issue using verified evidence
---
1. Read `WORKSPACE_STATE.md` and detect the project engine.
2. Search existing code, tests, logs, and relevant tickets without changing files.
3. Separate observations from hypotheses; inspect causal call paths.
4. Test hypotheses only with permitted read-only actions; request approval for state-changing validation.
5. Report Current State, Problem flow, Evidence, Ruled Out, and Unknowns using `REPORTING.md`.
6. Suggest a bounded plan; do not implement without approval.
