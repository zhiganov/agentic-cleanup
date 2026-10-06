---
name: agentic-cleanup
description: Scan a developer workstation for reclaimable disk space, report categorized findings, and clean only user-selected categories. Use when the user invokes /cleanup or asks for workstation disk cleanup.
---

# Safe Workstation Cleanup

This is an explicitly invoked scan → report → select → refresh → execute
workflow, not an ambient hook. Discovery never grants deletion authority. A
large file or an unfamiliar folder is evidence, not a cleanup candidate.

## Read on demand

Use [platform and category recipes](references/workflow.md) only for the relevant
heading: **Helper scripts** for resolution/integrity; **Step 1–2.5** for platform,
workspace and indexed discovery; **Cross-platform categories**, **Windows-only
categories**, or **Unix categories** for the applicable recipes; **Step 6** for
ordinary category mechanisms. Do not load the entire reference on every run.
This entry point governs safety, selection, accounting, and newer helper usage.

## Boundaries

- Delete only explicitly selected categories or individually approved outliers.
  `all` covers the curated category table, not expanded-audit letters, personal
  files, relocation, software uninstall, or a separate disk-space planner.
- Preserve source, active/unfinished worktrees, dependencies used by runtimes or
  registered MCP servers, personal files, and live runtime state. Git inactivity,
  apparent orphanhood, and unlocked files do not establish that data is dead.
- Protect memories, commands, skills, settings, history, and current/newest
  runtime installations. Never offer `hiberfil.sys`, paging-file deletion,
  manual WinSxS removal, manual Office/Edge/WebView2 removal, or service killing.
- Never open personal file contents or hydrate cloud files to measure them.
  Personal audits and unknown outliers are review-only. Do not follow junctions
  or links to expand an approved scope. Show incomplete coverage explicitly.
- Own every task worker through completion. Do not stop other apps, services,
  builds or agents to make a target deletable. Do not reboot or use `/ResetBase`.
- Scratch belongs to one unique run under the cleanup scratch root. Other runs,
  `%TEMP%\claude`, `%TEMP%\opencode`, and legacy cleanup scratch are excluded.
  Never delete a shared scratch root to clean up one run.

## Resolve and discover

- Follow **Helper scripts** in the reference to resolve this product's source or
  installed payloads and enforce release integrity. Announce the chosen copy.
  Missing/mixed helpers are a hard stop, not permission to rewrite inline code.
- Resolve the outermost workspace marker excluding the user home. Reject home,
  drive-root and `/` fallbacks for workspace-scoped categories. Say when a nearer
  subproject marker was passed. Never broaden a failed search to the user profile.
- Measure a scan baseline and get a refreshed process census. Recognized runtime
  count is not exact session attribution. Zero recognized OpenCode processes
  does not prove absence; report the census's limitations.
- Ordinary cleanup uses whole-drive indexed evidence when available, otherwise
  bounded top-consumer discovery plus applicable category recipes. A narrow
  personal-folder request uses only its selected folders, not a forced drive scan.
- `--dry-run` stops after the report. `--structured-preview` uses committed
  `scan.ps1` plus `render-scan.ps1` (PowerShell 7), then stops without a plan.

### Independent largest-file discovery (Windows)

Folder hotspots and individual files are separate reports. A folder grouping,
depth cap, or top-N must not silently hide a requested individual-file audit.

For an existing fresh WizTree export:

```text
python <helpers>/find_outliers.py <csv> --files --json --minimum-mb 50 --limit 100
```

For selected personal locations without a fresh index:

```text
python <helpers>/file_audit.py --known-folder Documents --known-folder Desktop --known-folder Downloads --known-folder Videos --output <unique-private-evidence.json>
```

Add `--known-folder OneDrive` only when selected; `Music` and `Pictures` are
independent scopes. Alternatively pass exact `--root` paths. This helper resolves
actual redirected Windows known folders, deduplicates overlapping roots and file
identities, reads metadata only, skips namespace links, and records absent,
inaccessible, partial, budget-limited and top-N coverage. It has no delete mode.
Use `--minimum-mib`, `--limit`, `--max-seconds`, and `--max-entries` to bound work.
Retain exact paths in private evidence; share only the metadata the user requested.

## Report and select

- Classify every material outlier: covered, confirmed reclaimable, close-app-first,
  human-review, protected/system-managed, or live dependency. Avoid overlapping
  parents/children and duplicate categories. Unknown paths stay informational.
- Use a configurable reporting threshold, default 50 MiB. Omit sub-threshold
  cleanup options from the queue; this does not preserve tiny files inside an
  explicitly selected cache scope. Label MiB/GiB accurately.
- Distinguish **logical bytes**, **locally allocated bytes**, **estimated uniquely
  reclaimable bytes**, and **observed net disk change**. Unsupported allocation
  is unknown, never zero. Cloud placeholders, compression, sparse files, hardlinks
  and junctions invalidate logical-size-as-recovery assumptions.
- Indexed allocation without file identity is not a deduplicated reclaim estimate.
  Installed-app registry sizes and raw WinSxS/backups totals are not recovery
  estimates. A package count cannot be converted into reclaimable bytes.
- Show top-N omission counts, skipped locations, bounds and measurement methods.
  Do not describe a partial walk as a complete drive census.
- Wait for the user to select exact numbered categories or expanded-audit items.
  A selection applies to the displayed paths and mode, not freshly discovered
  additional directories. Broader or substituted targets need new approval.

## Refresh and execute

- Snapshot free space immediately before the actual operation, not from the scan
  baseline. Retain per-operation measurements when several categories run.
- For migrated Windows categories use immutable `scan.ps1` → `build-plan.ps1` →
  `execute-plan.ps1`, which refreshes policy/root, links, liveness, ownership,
  completeness and freshness immediately before each operation. Selected absent
  build/dependency paths are validated no-ops; empty/malformed selection still
  fails closed. Inspect the persisted result, not merely the worker's exit code.
- For `.next/cache` contents only, create evidence with `scan.ps1 -BuildCacheOnly`
  and select the exact build-cache item. The dedicated policy retains the root,
  sibling build output, source and dependencies; never substitute whole `.next`.
  Preserve active builds and watchers even when their working directory cannot be
  attributed. Compare repository status and retained paths before/after.
- Legacy build-directory deletion goes through the structured path rather than
  `scrub.ps1`. Keep the 24-hour freshness guard and registered-owner checks.
  Other legacy lists still require `assert_list.py` with one required bucket per
  selected category, explicit exclusions and a fresh live-path veto. Do not use
  `grep -iF` on Windows or regex matching on backslash-laden paths.
- Use npm's own `_cacache` cleanup. Never delete the npm-cache or `_npx` root;
  only exact immediate `_npx` children passing refreshed age/parent/liveness gates.
- Browser/app caches require the owner to be closed. Preserve roots for contents-
  only actions, skip locks, and never retry harder by killing their holders.

### Windows logs and component maintenance

Use committed `maintenance.ps1` and the `windows_maintenance.ps1` library, not
wildcard CBS/OEM deletes or ad-hoc UAC scripts. `ScanLogs` writes exact rotated,
old-file evidence; `CleanLogs -EvidencePath <scan> -Approved` refreshes every
selected file's eligibility, metadata, liveness and lock state. Preserve CBS.log,
DISM.log, newest PC Manager logs per directory, changed/fresh/linked files, and
all log roots. Pass a new task-owned `-OutputPath` for every worker.

Mutation and DISM analysis require an already elevated trusted worker. If that
isn't available, return `manual-required`; do not silently auto-elevate user-
writable code. `-Verb RunAs` and stdout redirection are incompatible. A worker
writes its own structured result. Missing results are unknown/incomplete, not
proof that UAC was declined. Actual launch cancellation is a separate outcome.

`Analyze` runs supported English DISM analysis. `Components -Approved` checks
installer/update/pending-reboot state, waits at most 30 seconds (configurable up
to 120) for servicing workers to exit naturally, and runs one supported cleanup
pass with `/NoRestart`. A recent same-machine analysis can be reused only while
fresh and all current guards pass; otherwise reanalyze. Report native status,
post-analysis and remaining packages separately; do not automatically repeat a
successful pass. Never use `/ResetBase`, force reboot, or stop workers/services.

## Results and scratch

- `render-result.ps1 -ResultPath <result>` reports persisted operation statuses,
  logical scope decreases, unknown unique recovery and signed net disk change.
  Also inspect failures/warnings without dumping raw logs or command lines.
- Report completed, validated absent/no-op, fresh/active skips, locks/partial and
  failures separately. Zero worker exit alone does not prove completion.
- Remove only this run's verified scratch after all workers exit, and verify its
  physical absence. Keep any requested durable evidence outside scratch.
- Take the final free-space measurement after scratch removal. Label its interval;
  preserve negative net changes. Concurrent writes, cache regrowth and paging can
  change net recovery, but do not attribute a cause without evidence.
- Stop at the selected operation's outcome. A remaining target or deferred planner
  does not authorize another cleanup pass, relocation, uninstall or runtime change.
