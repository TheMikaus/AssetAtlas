---
name: architecture
description: Read, map, verify, and maintain the project's implemented architecture and design decisions
---
1. Read ARCHITECTURE.md, DECISIONS.md, WORKSPACE_STATE.md and selected engine rules; ask user for engine selection if not yet established for this project.
2. Inspect relevant source/configuration to verify documentation; label findings Verified, Inferred, Hypothesis, or Unknown.
3. Summarize actual components, boundaries, data flow, lifecycles, dependencies, and source links. Separate implemented from proposed behavior.
4. Identify stale documentation and contradictions; present evidence and suggested corrections.
5. Before any architecture change, present a bounded plan and obtain approval. Include architecture/decision document updates in the approved scope.
6. After approved implementation, update ARCHITECTURE.md for current design and DECISIONS.md for significant choices and rejected alternatives; keep both concise and linked to code.
7. Update WORKSPACE_STATE.md at approved milestones and before handoff or context compaction when possible. After compaction re-read relevant docs; hooks may be unavailable or interrupted.
8. Never claim files were updated unless writes succeeded. Source code and observed behavior override stale descriptions.
