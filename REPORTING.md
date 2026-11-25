# Reporting Templates

## Investigation / Slack synopsis
**Current State** — verified code/config, paths, links, short snippets.
**Problem** — numbered observed-to-failure causal flow; expected vs observed.
**Evidence** — logs, tickets, tests, metrics; tag uncertain claims.
**Ruled Out** — alternative hypotheses and disconfirming evidence.
**Required Changes** — changes and why.
**Proposal** — steps, affected files, risk, validation, approval status.
**Rejected Proposals** — alternatives and reasons.
Omit empty sections rather than fabricating details.

## CR / release status
- CR link and observed status; merge commit and branch if merged.
- Build/pipeline links and last verified stage; production state separately.
- Unknown or inaccessible stages.

## Daily standup / handoff
**Progress:** completed and verified items.
**Plans:** approved next steps, pending decisions.
**Problems:** blockers, failed checks, unknowns.
**User Directives:** explicit do/don't constraints.
**References:** paths, commits, tickets, CRs.
