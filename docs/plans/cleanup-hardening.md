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
- Keep all implementation in agentic-cleanup; update both installers and release
  integrity checks for every new resource. Do not create a second source repo.
- Verify focused fixtures, PowerShell parsing, distribution parity, and manifest
  inventory. No full test suite, dependency install, production build, paid model
  benchmark, service restart, or browser use is authorized.
- Commit/push the implementation branch and use agentic-cleanup#23. Review it,
  but do not merge, release or install runtime copies without explicit approval.

Ownership correction: agentic-cleanup is the sole code and tracker owner. The
former canonical/published duplication is rejected. claude-config#163 was closed
unmerged and its task-only branch removed; its default branch is unchanged.
Legacy runtime/config copies are preserved, but are not helper-resolution or
cross-repository synchronization targets. No ambient instructions are changed.

Status: ownership/source-resolution correction and local manifest generation are
complete. Isolated source/installer, scan-guard, cache, validator and executor
fixtures pass. The review reproduced and fixed directory-to-file cache deletion
and linked-dependency discovery aborts. No full suite or model benchmark ran.

Review blocker: replacing a directory with a junction between lstat and scandir
lets the metadata audit report an unselected target. The committed synthetic
repro confirms it. A larger identity-pinned/no-follow traversal repair requires
user approval before implementation or merge; it was not attempted in review.
No real elevated servicing, runtime installation, merge or release was performed.
