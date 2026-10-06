# Cleanup hardening — issues #22, #6, #10

Scope: explicitly invoked cleanup only. The disk-space planner (#21) remains
deferred. Do not run a real cleanup, install over user runtime copies, or change
shared hooks/services while developing this work.

- Reuse scan/plan/result provenance and policy checks; strengthen refreshes,
  absent-target handling, and an explicit cache-contents policy.
- Add metadata-only file discovery, actual known-folder resolution, coverage
  reporting, distinct logical/allocated/unknown reclaim accounting, and fixtures.
- Replace wildcard log deletion with exact old/unchanged/unlocked file evidence.
  Bundle conservative servicing guards and worker-owned DISM result handling.
- Split the large skill into a small entry point and on-demand references,
  preserving category recipes and safety boundaries.
- Synchronize canonical workflow/helpers in claude-config with this publication;
  update both installers and release integrity checks for every new resource.
- Verify focused fixtures, PowerShell parsing, distribution parity, and manifest
  inventory. No full test suite, dependency install, production build, paid model
  benchmark, service restart, or browser use is authorized.
- Commit/push implementation branches and open ordinary PRs against each repo's
  default branch. Stop at PR creation; retain checkout branches for review.

Status: implementation and focused synthetic fixtures complete; preparing the
two ordinary PRs. File-audit tests cover 11 scenarios; maintenance, cache-only,
executor, validator, scanner, census, fixed-category, outlier, installer and
manifest checks passed. No full-suite or model benchmark was run. Canonical
source remains claude-config; product tracking stays in agentic-cleanup.
Runtime installation, real elevated servicing, merge and release are not done.
