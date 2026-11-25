---
name: handoff
description: Produce a concise standup and persistent workspace handoff
---
1. Read existing `WORKSPACE_STATE.md` and current conversation decisions.
2. Produce Progress, Plans, Problems, User Directives, and References.
3. Request approval before writing the workspace file if not already approved.
4. Update only verified facts; mark unverified or stale items.
5. Never claim the handoff was saved unless the write succeeded.

- Capture architecture changes and significant decisions in ARCHITECTURE.md / DECISIONS.md when within approved scope; re-read these after compaction.
