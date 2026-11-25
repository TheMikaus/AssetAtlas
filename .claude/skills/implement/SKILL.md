---
name: implement
description: Implement an explicitly user-approved plan without scope expansion
---
1. Confirm the approved plan and exact scope from the conversation. If absent, stop and ask.
2. Read engine rules and inspect affected code and tests.
3. Implement minimal changes only within approval.
4. Stop for renewed approval on material discoveries or plan changes.
5. Propose/run tests only if their side effects are approved; report exact results.
6. Summarize changed paths, verification, and gaps.
