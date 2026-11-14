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

Unix/macOS instruction consistency checks:

```sh
python3 scripts/cleanup/tests/test-unix-safety-recipes.py
```

These check permission-denial handling, closed-owner/liveness requirements,
protected history and platform-specific measurement instructions across active
skill/portable/documentation consumers. They include a disposable POSIX fixture
showing that an open, advisory-locked file can be unlinked. They do not invoke a
cleanup executor, touch workstation caches or establish end-to-end Unix cleanup
validation.

Homebrew scope regression checks:

```sh
python3 scripts/cleanup/tests/test-homebrew-scope.py
```

These execute the maintained recipe's read-only Bash snippets against isolated
fake `brew`/`du` tools. They cover configured cache paths, retained downloads,
old installed versions in maintenance previews, non-selectable/manual-only
reporting, invalid/linked roots and unavailable measurements/previews. They never
invoke a real Homebrew installation, mutate workstation caches or validate a
Homebrew cleanup executor; the skill intentionally provides none.

## macOS read-only discovery

`macos_scan.py`, `macos_ownership.py` and `macos_report.py` require existing Python 3.10+ and are
distributed by both installers. They import the already-distributed file-audit
helper's POSIX metadata/descriptor primitives rather than duplicating traversal.
Optional depth/prune arguments leave its existing Windows audit defaults unchanged.

`purpose: read-only-macos-discovery` follows the read-only file-audit evidence
layer, not the Windows scan/plan schema: partial sizes can be null and coverage is
explicit. It has no cleanup policy/executor and must never enter the Windows plan
builder. All findings are non-selectable evidence. Process and static registration
gaps, linked/inaccessible/budget-limited scopes, overlap and top-N omissions are
reported without persisting commands, config bodies or opaque server names.

```sh
python3 scripts/cleanup/tests/test-macos-discovery.py -v
python3 scripts/cleanup/tests/test-macos-accounting.py -v
```

Fixtures exercise metadata-only discovery, bundle/cache ownership, registered-but-
idle consumers, JSONC, runtime/store siblings, hardlinks, budgets, redaction and
private exclusive evidence. On native macOS, an isolated installer plus integrity
preamble plus the installed CLI are exercised with temporary HOME/XDG/Claude roots
and process/tool probes disabled (explicitly unknown, not absent). No real app,
cache cleanup, user-runtime installation or dependency install is involved.

`macos_report.py render --input <scan-or-space.json> [--before <space.json>]`
renders saved private evidence without rescanning. It exposes coverage statuses,
skips, interrupted/uninspected discovery stages, top-N/threshold omissions and
identity-deduplicated observed subtotals. Item-row allocation is not additive or
uniquely reclaimable; APFS clone/snapshot sharing remains unknown.

`macos_report.py snapshot --path <exact-existing-retained-directory> --output <new.json>`
records bounded per-device observations (repeat `--path`, at most 32 paths,
16 devices, 15 seconds). The scanner uses the same collector for baseline and
target filesystem association. `fstatvfs` on a pinned descriptor measures bytes;
`df -Pk` discovers a block device whose `st_rdev` must match the mounted-filesystem
ID from the pinned descriptor's `fstatvfs.f_fsid` before `diskutil info -plist` supplies allowlisted identity/container
metadata. Unsupported devices or identity failures remain explicit gaps. No
mount/unmount, snapshot enumeration, purge, or filesystem mutation is performed.

APFS System/Data paths can share file/inode `st_dev` while their mounted
filesystem IDs differ. Cache by `f_fsid`, never by `st_dev`; the latter is retained
only as an inode-device observation and expected-root check. Missing `f_fsid`
gets an isolated unknown observation, never a guessed volume association.
Each scope reports byte-observation status separately from identity status.
Failed cached identities stay unknown without retries. Safe diagnostics identify
the failed stage/code and optional numeric exit/errno; raw plists, command output,
volume names and exception text are excluded. Missing/invalid UUIDs cannot
produce verified identities or signed deltas.

No aggregate capacity/free-space total is emitted. System/Data observations may
share a container, while external devices remain separate. APFS quota/reserve,
clone/snapshot and purgeable semantics prevent treating logical or allocated
bytes as unique recovery. Nested mountpoints in measured targets are omitted
and make coverage partial; shared traversal defaults are unchanged elsewhere.

Fresh matching UUID/method/time observations produce a signed available-byte
interval change, never a causal cleanup claim. Missing/duplicate/unidentified/
invalid pairs stay unknown; shared-container deltas are not summed. The caller
must keep operation status and selected-scope decrease separate, snapshot
immediately before each operation, and take final observations after scratch
removal. Save final evidence outside scratch and disclose its subsequent write.
