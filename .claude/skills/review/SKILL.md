---
name: review
description: Independently review gameplay code and engine-specific risks
---
1. Identify the intended change and review scope.
2. Inspect diff and surrounding code; compare to approved plan.
3. Check behavior, regressions, lifetime/threading, serialization, performance, and tests.
4. List findings by severity with paths/lines and evidence; distinguish hypotheses.
5. Do not edit code or tests without a new approved plan.
