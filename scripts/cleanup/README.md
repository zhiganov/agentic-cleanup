# Cleanup Contracts

The structured `/cleanup` pipeline separates evidence, approval, validation,
execution, and results:

- `Cleanup.Contracts.psm1` owns normalized digests, schema checks, semantic
  checks, and immutable JSON writes.
- `policies/windows.v1.json` allowlists policy, executor, mode, elevation, root,
  and refreshed-precondition combinations. It contains no commands.
- `build-plan.ps1` projects stable category/item selections from an immutable
  scan into an immutable plan.
- `validate-plan.ps1` rechecks digest, identity mappings, path classes,
  existence, reparse points, process liveness, build freshness, registered MCP
  ownership, and installer activity.
- `render-scan.ps1` renders persisted evidence without substituting logical
  bytes for an unknown reclaim estimate.
- `render-result.ps1` keeps logical scope changes separate from signed net disk
  changes, per-operation snapshots, and unknown unique recovery. Result byte
  measurements may be null when metadata is unavailable; zero means measured zero.
- `schemas/` contains the versioned scan, plan, and result contracts.

Windows producers and executors live under `scripts/windows/cleanup/`:

- `scan.ps1` currently covers six representative operation classes, including
  inactive `node_modules` with registered-MCP protection. Non-Git projects are
  distinguished from repository-backed projects whose Git inspection fails;
  the latter stop the scan.
- `registered_mcp.ps1` discovers static Claude Code and OpenCode V2 local MCP
  ownership without persisting commands, arguments, environment, or secrets.
  Recognized unresolved environment placeholders fail discovery closed; inline
  shell command bodies are not misclassified as filesystem paths.
- `execute-plan.ps1` dispatches only registered executors and writes a verified
  result. It never launches user-writable code through UAC; elevated operations
  require an already elevated trusted process or return `manual-required`.
- `live_paths.ps1 -JsonSummary` reports Claude Code and OpenCode runtime census
  evidence without inferring exact OpenCode session ownership.
- `scan.ps1 -BuildCacheOnly` and `build-cache-contents` policy retain exact
  `.next/cache` roots and siblings. Absent selected build/dependency targets are
  refreshed no-ops, not an excuse to drop assertion buckets or broaden selections.
- `file_audit.py`, `path_evidence.ps1`, and `maintenance.ps1` provide bounded
  metadata discovery, shared completeness checks, and conservative old-log/DISM
  handling. They never authorize a real cleanup as part of development tests.

## Verification

Run from the repository root:

```powershell
pwsh -NoProfile -File scripts/cleanup/tests/test-schemas.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-contracts.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-live-paths.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-registered-mcp.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-scan.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-render-scan.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-plan-builder.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-validator.ps1
pwsh -NoProfile -File scripts/cleanup/tests/test-executor.ps1
```

All tests use fixtures or disposable temp directories. They never clean the
workstation or request elevation.

New focused regressions (do not replace a requested verification budget with an
automatic full suite): `test-file-audit.py`, `test-build-cache.ps1`, and
`test-maintenance.ps1`. These cover redirected/nested files, placeholders,
hardlinks, allocation failures, links, coverage/top-N, disappearing caches,
fresh writes, retained siblings, signed disk deltas, log locks, servicing waits,
analysis freshness, and worker outcome interpretation.
