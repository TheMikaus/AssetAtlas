---
name: test
description: Plan and execute approved engine-appropriate validation
---
1. Detect engine/version and locate existing tests and build scripts.
2. List proposed commands, generated-file side effects, and acceptance criteria.
3. Obtain approval before commands that modify state.
4. Run targeted checks first; broaden only as approved.
5. Report exact commands, pass/fail/skip, reproducibility, and coverage gaps.
6. For regression tests, verify they would detect the original failure when feasible.
