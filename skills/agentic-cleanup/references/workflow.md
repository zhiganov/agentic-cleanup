# Platform and Category Recipes

Read only the named section needed by SKILL.md, not this whole reference. The
entry-point safety rules and committed helper guards override historical recipe
examples if they differ.

## Contents

- Helper scripts / integrity and workspace resolution
- Step 1–2.5: platform detection and indexed discovery
- macOS committed discovery (ordinary scans, including dry-run)
- First-scan runtime and cache inventory (before the ordinary report)
- Step 3: Cross-platform categories
- Step 3: Windows-only categories
- Step 3: Unix categories (Linux + macOS)
- Step 4–5: reporting and exact selection
- Step 6–7: execution and result accounting

Scan the workstation for reclaimable disk space, report findings in a categorized table, let the user select which categories to clean, and execute the cleanup.

## Governing discovery principle

Discovery is evidence-first, not category-limited. Start with whole-drive or
whole-filesystem top consumers and unexpected outliers, then apply the curated
categories as safety policies and known cleanup mechanisms. Fixed categories
must never define the boundary of what the scan can discover.

Every material outlier must be classified as confirmed reclaimable,
reclaimable after closing an application, requiring human review,
system-managed/protected, or a live dependency. Unknown paths are evidence, not
deletion targets. Broad runtime exclusions are deletion boundaries rather than
visibility boundaries: inspect descendants read-only for abandoned worktrees,
build outputs, caches, and task artifacts while preserving anything live.

**Never suggest deleting `hiberfil.sys` or disabling hibernation.** Suppress it
from outlier output and treat it as protected system functionality in every
scan, report, and cleanup plan.

## Platform coverage

The skill detects the OS at runtime and only scans categories that apply. Coverage status as of the latest revision:

| Platform | Status | Notes |
|----------|--------|-------|
| Windows (MSYS2/Git Bash) | **Validated** | Original development target; 12 Windows-only categories plus the cross-platform set, including elevated cleanup, WizTree fast-scan integration, AppData remnants, VS / SDK orphans, Electron app caches, and Squirrel pruning. |
| Linux — Fedora (dnf/rpm) | **Validated** | Tested on Fedora 44 with the orphan scan's 4-layer filter chain (allowlist + active-binary + 30-day mtime + token-boundary package match). |
| Linux — Debian/Ubuntu (apt) | Scan exercised, **clean not exercised** | Dry-run scan run on Ubuntu 26.04 under WSL2 (2026-10-26): detection and measurement worked. Clean commands have not been run. **Under WSL2, `df /` reports the virtual disk's ceiling (default 1 TB), not free space on the Windows host drive** — report that the real constraint is the host drive, and that space freed inside WSL2 returns to the host only after the `ext4.vhdx` is compacted. |
| Linux — Arch (pacman), openSUSE (zypper) | Written, **not exercised** | Same as Debian — logic exists, untested. |
| macOS | Read-only scanner and isolated installation exercised; **automated cleanup not validated** | Committed Python discovery/ownership adapter with native macOS disposable fixtures. Actual workstation cleanup is not established by a dry run or manual in-app clearing. |

If you run this on an untested distro and something misbehaves, the category guards mean it'll fail loud rather than damage the system — the scan reads, then the user explicitly picks what to clean.

## Arguments

Parse the optional arguments supplied by the invoking command. If they contain `--dry-run`, operate in report-only mode (skip selection and deletion steps). If they contain `--structured-preview`, run the committed six-category Windows contract preview described below and stop after rendering its immutable scan.

## Instructions

## Helper scripts (all platforms)

The Windows scan/delete helpers and macOS read-only adapter are **committed files**.
Do not recreate them as per-run inline scanners. Windows backslash literals get
mangled inside heredocs, and hardcoded `/tmp/...` paths are not MSYS-converted.
This repository is the sole source; installed payloads are release consumers.
Resolve one complete root for helpers and contracts. Legacy copies in other
repositories are not candidates and are not compared or synchronized:

```bash
# Workspace root = the OUTERMOST ancestor containing .claude, .opencode,
# opencode.json, or opencode.jsonc,
# EXCLUDING $HOME. Not the innermost: subprojects carry their own marker, and stopping at the first
# one silently scopes every workspace category to a subtree (see Step 2).
# Not the plain outermost either: ~/.claude is the user-level config, not a workspace
# marker, so "take the last hit" resolves to $HOME. Both traps are real; see Step 2.
resolve_root() {
  local d best home
  home="$(cd "$HOME" 2>/dev/null && pwd -P)"
  d="$(pwd -P)"; best=""
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if { [ -e "$d/.claude" ] || [ -e "$d/.opencode" ] || [ -f "$d/opencode.json" ] || [ -f "$d/opencode.jsonc" ]; } && [ "$d" != "$home" ]; then best="$d"; fi
    d="$(dirname "$d")"
  done
  printf '%s\n' "${best:-$(pwd -P)}"
}
root="$(resolve_root)"
agentic_data="${AGENTIC_CLEANUP_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agentic-cleanup}"
source_checkout=""
if command -v git >/dev/null 2>&1; then
  source_checkout="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
CLEANUP_ROOT=""
for payload in "$root/agentic-cleanup" "$source_checkout" "$root" "$agentic_data"; do
  [ -n "$payload" ] || continue
  # Source roots must identify this product, not an arbitrary helpers directory.
  if [ "$payload" != "$agentic_data" ]; then
    [ -f "$payload/install.sh" ] && [ -f "$payload/install.ps1" ] || continue
  fi
  [ -f "$payload/cleanup.md" ] && \
  [ -f "$payload/skills/agentic-cleanup/SKILL.md" ] && \
  [ -f "$payload/skills/agentic-cleanup/references/workflow.md" ] && \
  [ -f "$payload/scripts/windows/cleanup/wt_lookup.py" ] && \
  [ -f "$payload/scripts/cleanup/Cleanup.Contracts.psm1" ] && CLEANUP_ROOT="$payload" && break
done
[ -n "$CLEANUP_ROOT" ] || { echo "STOP: no complete agentic-cleanup source or installed payload; use the product's installer"; exit 1; }
CLEANUP_SCRIPTS="$CLEANUP_ROOT/scripts/windows/cleanup"
CLEANUP_CONTRACTS="$CLEANUP_ROOT/scripts/cleanup"
echo "CLEANUP_ROOT = $CLEANUP_ROOT"

# An installed payload must be bound to the active runtime command and skill pair.
installed_helpers="$agentic_data/scripts/windows/cleanup"
if [ "$CLEANUP_ROOT" = "$agentic_data" ]; then
  manifest="$agentic_data/install-manifest.sha256"
  [ -f "$manifest" ] || { echo "STOP: installed cleanup manifest is missing; reinstall /cleanup"; exit 1; }
  manifest_paths=(
    cleanup.md
    skills/agentic-cleanup/SKILL.md
    skills/agentic-cleanup/references/workflow.md
    scripts/windows/cleanup/{wt_lookup.py,find_targets.py,find_outliers.py,file_audit.py,path_evidence.ps1,windows_maintenance.ps1,maintenance.ps1,assert_list.py,live_paths.ps1,registered_mcp.ps1,diskspace.ps1,run_wiztree.ps1,squirrel.ps1,appdata_orphans.ps1,winsdk.ps1,vs_orphans.ps1,scrub.ps1,scan.ps1,execute-plan.ps1,README.md}
    scripts/cleanup/{Cleanup.Contracts.psm1,build-plan.ps1,validate-plan.ps1,render-scan.ps1,render-result.ps1,macos_scan.py,macos_ownership.py,macos_report.py,README.md,schemas/scan.schema.json,schemas/plan.schema.json,schemas/result.schema.json,policies/windows.v1.json}
  )
  [ "$(wc -l < "$manifest" | tr -d ' ')" -eq "${#manifest_paths[@]}" ] || \
    { echo "STOP: installed cleanup manifest inventory is incomplete; reinstall /cleanup"; exit 1; }
  for path in "${manifest_paths[@]}"; do
    [ "$(awk -v path="$path" '$(2) == path { n++ } END { print n + 0 }' "$manifest")" -eq 1 ] || \
      { echo "STOP: installed cleanup manifest inventory is invalid: $path"; exit 1; }
  done
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$agentic_data" && sha256sum -c --quiet install-manifest.sha256)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$agentic_data" && shasum -a 256 -c install-manifest.sha256 >/dev/null)
  else
    false
  fi || \
    { echo "STOP: installed cleanup files are mixed or corrupt; reinstall /cleanup"; exit 1; }
  if [ "${OPENCODE_TERMINAL:-}" = "1" ]; then
    runtime_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  elif [ -n "${CLAUDECODE:-}" ]; then
    runtime_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  else
    echo "STOP: unable to identify the active cleanup runtime; reinstall or run from OpenCode or Claude Code"
    exit 1
  fi
  command_copy="$runtime_dir/commands/cleanup.md"
  skill_copy="$runtime_dir/skills/agentic-cleanup/SKILL.md"
  [ ! -L "$command_copy" ] && [ -f "$command_copy" ] && cmp -s "$agentic_data/cleanup.md" "$command_copy" || \
    { echo "STOP: active runtime command copy does not match this release: $command_copy"; exit 1; }
   [ ! -L "$skill_copy" ] && [ -f "$skill_copy" ] && cmp -s "$agentic_data/skills/agentic-cleanup/SKILL.md" "$skill_copy" || \
     { echo "STOP: active runtime skill copy does not match this release: $skill_copy"; exit 1; }
   reference_copy="$runtime_dir/skills/agentic-cleanup/references/workflow.md"
   [ ! -L "$reference_copy" ] && [ -f "$reference_copy" ] && cmp -s "$agentic_data/skills/agentic-cleanup/references/workflow.md" "$reference_copy" || \
     { echo "STOP: active runtime reference does not match this release"; exit 1; }
fi
```

**Use one product root; refuse mixed releases.** The resolver never imports or
compares another repository's source. For a source checkout, invoke this repo's
command and skill, and verify its normalized manifest with
`python scripts/cleanup/update-manifest.py --check` before running helpers.
Installed payloads must pass the inventory/hash and active-runtime checks above.
Do not use a legacy skill together with newer helpers, and do not copy missing
resources from another repo. A missing or mismatched release is a hard stop.

**Never let an install artifact shadow the source on a maintainer machine.** The installers write the selected global runtime command copies plus a shared payload under the user data directory. A global Claude Code command **outranks the project junction**, while an OpenCode project command outranks its global copy. Test installers only with temporary `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` values; do not install snapshots over the canonical maintainer setup.

Stale or mixed helpers can omit ownership protections even when their scan output
looks plausible. Release integrity, exact source selection and per-operation
validation are safety gates, not a reason to maintain duplicate implementations.

| Script | Purpose |
|--------|---------|
| `wt_lookup.py <csv>` | Size lookup — pipe Windows paths on stdin → `sizeMB\|path` |
| `find_targets.py <csv> <workspace_root>` | Top-level `node_modules` (≥10 MB) + `.next`/`.turbo`/`.parcel-cache`/`.vite` dirs under the workspace |
| `find_outliers.py <csv> [--minimum-mb 100]` | Read-only, non-overlapping whole-drive hotspots; suppresses `hiberfil.sys` |
| `diskspace.ps1 [drive]` | `free total pct` in GB (default = system drive) |
| `run_wiztree.ps1 -WizTree <exe> -OutCsv <winpath>` | Elevated WizTree MFT export (one UAC) |
| `squirrel.ps1` | Discover Squirrel old `app-*` versions |
| `appdata_orphans.ps1` / `winsdk.ps1` / `vs_orphans.ps1` | Windows orphan / old-version discovery |
| `live_paths.ps1 [-Summary]` | Paths RUNNING processes depend on (stdout); session + MCP-server census on stderr |
| `registered_mcp.ps1` | Discover static Claude Code and OpenCode V2 local MCP ownership without exposing commands or secrets |
| `scan.ps1` | Emit an immutable, schema-validated six-category Windows evidence scan |
| `assert_list.py <list> --require L=SUB --forbid L=SUB --live <paths>` | **Gate before `scrub.ps1`** — buckets the list, fails on a missing/forbidden/unclassified/live entry |
| `scrub.ps1 -ListFile <file>` | Hook-safe batch deleter (one path per line) |
| `execute-plan.ps1` | Validate and run only operations resolved through the committed policy registry; elevated targets require an already elevated trusted process |

PowerShell helpers: `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/<name>.ps1")" …`. Python helpers: `python "$CLEANUP_SCRIPTS/<name>.py" …`. Always pass the CSV path and workspace root as **command-line arguments** (MSYS converts those). If the payload cannot be resolved or verified, stop; do not substitute another repo's helpers or re-author them inline.

### Step 1: Detect Platform and Measure Disk Space

Create a temp directory for cleanup scripts (on Windows, `/tmp/` maps to `%TEMP%` which gets cleaned by the temp files category — using a subdirectory lets us exclude it):
```bash
mkdir -p /tmp/agentic-cleanup
```

Run:
```bash
uname -s
```

Determine platform:
- Output starts with `MINGW` or `MSYS` → **windows**
- Output is `Darwin` → **macos**
- Output is `Linux` → **linux**

For `--structured-preview`, require Windows, PowerShell 7 (`pwsh`), and both resolved helper directories, then run the committed evidence path and stop:

```bash
scan="/tmp/agentic-cleanup/scan-$(date +%s).json"
pwsh -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/scan.ps1")" \
  -OutputPath "$(cygpath -w "$scan")" \
  -WorkspaceRoot "$(cygpath -w "$root")" \
  -HelpersDirectory "$(cygpath -w "$CLEANUP_SCRIPTS")" \
  -ContractDirectory "$(cygpath -w "$CLEANUP_CONTRACTS")"
pwsh -NoProfile -File "$(cygpath -w "$CLEANUP_CONTRACTS/render-scan.ps1")" \
  -ScanPath "$(cygpath -w "$scan")"
```

This preview is read-only. It covers the first migrated categories: npm cache with `_npx` protection, user temp with runtime scratch exclusions, inactive build artifacts with freshness evidence, Config.Msi, and manual-only Windows.old. It never builds a plan or executes cleanup. Continue with the existing full-category path for ordinary `/cleanup` and `/cleanup --dry-run` until the remaining categories are migrated.

#### Free-space measurement (platform dispatch)

Measure current disk space as the **scan baseline**, not the execution "before":

- **Windows:** Resolve `$CLEANUP_SCRIPTS` (see *Helper scripts*), then run `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/diskspace.ps1")"`. Parse output: `free_gb total_gb used_pct`. This is the **scan baseline**; the summary's "before" is a fresh snapshot taken immediately before deletion in Step 6.

- **macOS:** Use the committed scanner's `filesystemSpace` for the scan baseline,
  then `macos_report.py snapshot` below for fresh per-operation/final observations.
  It measures `fstatvfs` on a pinned no-follow existing directory, uses `df -Pk`
  only to discover a device, validates that block device against mounted-filesystem
  `f_fsid` (not inode `st_dev`), and
  reads bounded `diskutil info -plist` metadata. A failed identity check is a gap,
  not a different volume's measurement. Never substitute the root volume for Data.
- **Linux:** Run `df -Pk "$root"` for the workspace scan baseline. For
  execution measurements run `df -Pk "<selected path or verified existing parent>"`
  on the selected target's filesystem. Parse available 1024-byte blocks and retain
  bytes (`available * 1024`); human-readable rounded values are display only.
  No PowerShell or Windows helper is required on Unix.

For each selected operation, record the target filesystem and an existing parent
that will remain after cleanup. On Windows pass that target's drive to the helper
rather than assuming the system drive. Repeat the same platform-specific method
on the same filesystem immediately before execution and after that run's scratch
removal. Keep different filesystems separate. Failed, inaccessible or malformed
measurements are **unknown, never zero**; do not claim a recovery delta without a
valid matching pair. Step 6 and Step 7 use this dispatch, not a Windows-only call.

**Take a session census (Windows).** Run `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/live_paths.ps1")" -Summary > /dev/null` and report the stderr census to the user before scanning:

```
claude code sessions live: 2
  pid=25656  mcp_servers=12  session=deliberation loop
  pid=21948  mcp_servers=12  session=Avails - standing availability epic
```

Concurrency is a **safety** condition, not just an accounting nuisance. Each extra session brings its own set of MCP servers executing from `npm-cache\_npx`, its own `%TEMP%\claude` scratch, and its own builds landing in projects whose git looks cold. When the census shows more than one session:

- Say so in the Step 4 report — the user should know another agent may be mid-flight.
- Treat every "is this dead?" judgement as unreliable and lean on `--live` (Step 6), not on git or the registry.
- Do **not** try to make the other session's files safe by killing anything. Never blanket-kill `node`/`node.exe` — that is what MCP servers are.

*Measured 2026-07-16:* two sessions live, **12 MCP servers each**, all 24 correctly attributed to their owning `claude.exe` by parent chain. This is not a rare condition — assume another session exists.

### Step 2: Detect Workspace Root

Use the `resolve_root` function from *Helper scripts* — **do not re-derive this walk inline.** `$WORKSPACE_ROOT` is the `root` it returns; it feeds the node_modules and build-artifact categories and the `$CLEANUP_SCRIPTS` probe.

The rule is: **the outermost ancestor containing `.claude`, `.opencode`, `opencode.json`, or `opencode.jsonc`, excluding `$HOME`.** Both halves matter, and each corresponds to a real failure:

- **Not the innermost.** Subprojects carry their own Claude Code or OpenCode configuration. Stopping at the first hit scopes every workspace category to whatever subtree you happen to be standing in. On 2026-07-16 the session had `cd`'d into `claude-project/scenius-digest` for an unrelated task, so the walk halted there and the real root — `claude-project` — was never reached. **The failure is silent: no error, just a small number**, which reads as a clean workspace rather than a mis-scoped scan. Worse, the helper probe is `$root`-relative, so a wrong root can silently select a different installed helper copy. A wrong root doesn't just under-report; **it can silently swap the safety-filtered script for an unfiltered one.**
- **Not the plain outermost either.** `~/.claude` **is** a `.claude` directory, so "keep walking and take the last hit" resolves the root to **`$HOME`** — verified, not hypothetical. That is worse than the bug it fixes: `find_targets.py` filters purely by path prefix, so a `$HOME` root sweeps `AppData/Roaming/npm/node_modules` (globally installed CLIs), `AppData/Local/Microsoft/TypeScript/*/node_modules` (the LSP), and `npm-cache/_npx/*/node_modules` (**live MCP servers**). None have a `.git`, so all read as inactive and get offered. `backs_mcp_server()` rescues the `_npx` ones; nothing rescues your global npm packages or the TypeScript LSP.

**Announce the resolution, and name the subproject you walked past** — a root that surprises the user must be visible, since the whole failure mode is silence:

```bash
echo "workspace root : $root"
nearest="$(pwd -P)"; while [ "$nearest" != "/" ] && [ ! -e "$nearest/.claude" ] && [ ! -e "$nearest/.opencode" ] && [ ! -f "$nearest/opencode.json" ] && [ ! -f "$nearest/opencode.jsonc" ]; do nearest="$(dirname "$nearest")"; done
[ -n "$nearest" ] && [ "$nearest" != "/" ] && [ "$nearest" != "$root" ] && \
  echo "  note: nearer agent config at $nearest (subproject) — scanning the WHOLE workspace, not just it"
```

**Guard against profile-wide roots.** If `resolve_root` falls back to the cwd and that cwd is `$HOME`, a drive root, or `/`, the workspace-scoped categories would enumerate the user profile. Skip them — the rest of the run is still valid:

```bash
home="$(cd "$HOME" && pwd -P)"; WORKSPACE_SCOPED=1
case "$root" in
  "$home"|/|/[a-z])
    echo "WARNING: workspace root resolved to '$root' — node_modules and build-artifact"
    echo "         categories would enumerate AppData (global npm packages, the TypeScript"
    echo "         LSP, npm-cache/_npx live MCP servers). SKIPPING those two categories."
    echo "         cd into the workspace and re-run if you wanted them."
    WORKSPACE_SCOPED=0;;
esac
```

If `$WORKSPACE_SCOPED` is 0, skip the node_modules and Build Artifacts categories and say so in the report. Do **not** substitute a narrower root to make them run.

### macOS committed discovery

For ordinary macOS `/cleanup`, including `--dry-run`, use the verified installed
or source `scripts/cleanup/macos_scan.py` once. This replaces improvised cache,
application, runtime and workspace traversal; it does not replace a narrow
personal-folder audit or the Windows structured preview. Require an existing
Python 3.10+ (`command -v python3`); if unavailable, stop and report the dependency.
Never install Python or fall back to a newly invented scanner implicitly.

Create one private task-owned run directory under the approved cleanup scratch
root. Use its physical path (system temp aliases are not input scan roots), then:

```bash
python3 "$CLEANUP_CONTRACTS/macos_scan.py" --cwd "$PWD" \
  --max-seconds 45 --max-entries 250000 --max-depth 20 --limit 100 \
  --output "<physical-private-run-directory>/macos-discovery.json"
```

The entry point resolves the outermost workspace marker excluding home, reports
a passed nearer marker, and rejects home/root fallbacks for workspace categories.
It uses the existing `file_audit.py` POSIX descriptor scopes and allocation methods,
not a duplicate walker. All Mac modules and that shared helper must belong to the
same verified payload. JSON evidence is a new exclusive mode-0600 file; never
overwrite another run's evidence. Clean only this run's scratch after reporting,
including dry-run reports, using the governing scratch-lifecycle rules.

Discovery covers bounded Library cache roots, exact known browser/Electron cache
subtrees, known-owner sandbox `Data/Library/Caches` (not whole containers),
allowlisted tool-cache overrides, configured npm cache metadata, runtime release
families/current/newest selectors, pnpm generation siblings, and scoped workspace
dependency/build directories. Application names come from bounded bundle plist
metadata. Current/newest/live/unknown-version runtimes stay protected; incomplete
pin/update ownership keeps older versions review-only. Homebrew remains manual-only.
Do not run duplicate filesystem scans for these items. Supplement only uncovered
tool-native categories such as Docker using their applicable existing recipes.

Process/open-path and static Claude/OpenCode V2 registration evidence are
separate. A registered local server can protect project dependencies even while
idle and launching from sibling `dist/`. Sources include global/system and bounded
ancestor/project configurations; JSONC comments/trailing commas are supported.
Only launch/cwd path fields are interpreted; commands, credentials, environment
bodies and opaque server names are never written to evidence. Dynamic/managed,
shell, unresolved-variable and package-only ownership gaps remain explicit.
Positive matches protect scopes; absent matches or zero recognized runtimes do
not prove non-use. No tool/runtime launcher is executed to learn its version.

Inspect `coverage`, bounds, top-N omissions, process/MCP limitations and each
item's classification before rendering the report. Partial/inaccessible/linked,
changed, budget-limited or unknown allocation stays unknown, not measured zero.
No user file contents or cloud placeholders are read to measure payload size.
Group containers, whole profiles, application state, VM disks, source and history
are not disposal candidates. Prefer supported in-app cache controls where useful;
a manually cleared item is user-reported until measured and proves no byte gain.

`purpose: read-only-macos-discovery` is the file-audit evidence layer, **not** a
Windows `scan.schema.json` plan input. Every item has `selectable: false`; there
is no new cleanup executor or registry. Never feed it to `build-plan.ps1` or turn
it directly into a deletion list. Category recipes still require independent
eligibility, exact selection and refreshed execution checks. Incomplete static
MCP ownership cannot be overridden with Git inactivity or an ad-hoc fallback.
The scanner records actual target filesystem IDs for measured existing scopes.
Nested mountpoints are not traversed in a target measurement; these omissions
make its size partial. Explicit external cache roots are measured separately.
Root, home and workspace baseline observations are associated with their devices,
not assumed to be the same filesystem. APFS System/Data volume groups and shared
containers are informational relationships, never independent pools to add up.
Observation caching uses the pinned descriptor's `fstatvfs.f_fsid`: APFS paths
can share inode `st_dev` while belonging to different mounted filesystems.
`st_dev` still guards expected file/root identity, not mounted-volume identity.
A missing filesystem ID produces an isolated unknown observation; failed identity
lookups are not promoted to verified associations or automatically retried.
Safe diagnostic stage/code plus numeric exit/errno fields explain discovery,
device verification, plist parsing and required UUID failures. Raw command output,
plists, volume names and exception text are never included in diagnostics.
Capacity/free readings are non-additive observations; quotas/reserves, snapshots,
clones and purgeable sharing prevent a uniquely reclaimable estimate. Deduplicate
file identities, but do not treat distinct clone identities as distinct physical
extents. `stat-blocks` allocation is not unique recovery.

Render the saved scan without another filesystem walk:

```bash
python3 "$CLEANUP_CONTRACTS/macos_report.py" render \
  --input "<physical-private-run-directory>/macos-discovery.json"
```

The report includes per-filesystem observations, complete/partial/inaccessible/
linked/budget/omitted scopes, unfinished discovery stages, skips, top-N and
threshold exclusions. A finished bounded stage does not mean full coverage;
read its per-scope gaps. Subtotals include observed identities in omitted rows;
never sum overlapping/hardlinked item rows or relabel subtotals as recovery.
Process/MCP limitations remain separate from size coverage.

For each independently approved operation, choose exact existing retained parent
directories on every affected filesystem. Take a new snapshot immediately before
the operation (not the scan baseline), retain per-operation snapshots when several
categories run, and repeat the same paths after that run's scratch is removed:

```bash
python3 "$CLEANUP_CONTRACTS/macos_report.py" snapshot \
  --path "<retained-physical-parent>" --output "<private-durable-evidence>/before.json"
# Approved operation and task-owned scratch removal occur separately.
python3 "$CLEANUP_CONTRACTS/macos_report.py" snapshot \
  --path "<same-retained-physical-parent>" --output "<private-durable-evidence>/after.json"
python3 "$CLEANUP_CONTRACTS/macos_report.py" render \
  --input "<private-durable-evidence>/after.json" --before "<private-durable-evidence>/before.json"
```

Each output is new/exclusive/private; repeat `--path` for separate filesystems
(at most 32 paths, 16 devices, 15 seconds per snapshot). These observations do not
clean anything or prove operation success. Write final evidence outside scratch;
disclose its small write after measurement. A delta requires one verified matching
volume UUID, method and valid chronological readings; otherwise it is unknown.
Report signed available-byte change, including negative values, separately from
operation outcome and selected-scope decrease. Shared-container deltas must not be
summed. No causal attribution to cleanup/concurrent writers/regrowth/paging is
established by a delta. This adds no history planner or automatic operation.

Apple documents APFS shared space, volume groups, quotas and reserves in
[Disk Utility guidance](https://support.apple.com/guide/disk-utility/add-delete-or-erase-apfs-volumes-dskua9e6a110/mac).

Explicit `--home`, `--applications`, and `--system-config-root` arguments bound
alternate read-only roots. `--no-process-probe`/`--no-tool-probe`/`--no-space-probe` disclose missing
evidence, never absence; they cannot grant eligibility. They are useful for
disposable fixtures, not substitutes for normal ownership evidence.

### Step 2.5: WizTree Fast Scan (Windows only)

**Skip if platform is not windows.**

WizTree reads the NTFS Master File Table directly, providing instant directory sizes for the entire drive. When available, it replaces all slow PowerShell `Get-ChildItem` size measurements.

**Check if WizTree is installed:**

```bash
find "/c/Program Files/WizTree" "/c/Program Files (x86)/WizTree" "$LOCALAPPDATA/Programs/WizTree" -maxdepth 1 -name "WizTree64.exe" 2>/dev/null | head -1
```

Also check: `command -v WizTree64` and `where.exe WizTree64.exe 2>/dev/null`

**If WizTree is found**, run the export. **CRITICAL:** WizTree's instant scan reads the NTFS Master File Table, which **requires elevation**. Without admin it silently falls back to per-file enumeration that is as slow as `Get-ChildItem` and **times out on a large or near-full drive** (Windows, 2026-06-23: `/admin=0` non-elevated hit the 2-5 min tool timeout with no CSV — and so did plain `du`/`Get-ChildItem -Recurse` sizing). So run it **elevated** (one UAC prompt) via the native PowerShell tool, using a Windows path for the export (the Windows form of `/tmp/agentic-cleanup/wiztree.csv`, i.e. `%TEMP%\agentic-cleanup\wiztree.csv`):

```bash
powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/run_wiztree.ps1")" -WizTree "<path_to_WizTree64.exe>" -OutCsv "$(cygpath -w /tmp/agentic-cleanup/wiztree.csv)"
```

`run_wiztree.ps1` encodes the elevation (it self-elevates via `Start-Process -Verb RunAs` and runs `/admin=1 /silent`), so the `/admin=0` timeout can't recur.

Then **verify the CSV** (a full-drive export is typically 100-300 MB; this drive produced 215 MB). If elevation is declined or the CSV is missing, fall back to PowerShell-based scanning — but expect it to be slow on a full disk, so scope it to the specific category paths rather than recursive whole-tree sizing.

**If WizTree is NOT found**, check if a recent WizTree CSV already exists in the workspace (the user may have exported one manually):

```bash
find "${OPENCODE_WORKSPACE_ROOT:-$PWD}/agentic-cleanup" -maxdepth 1 -name "WizTree*.csv" -newer /tmp/agentic-cleanup 2>/dev/null | head -1
```

If a CSV is found (either exported or pre-existing), use the committed `wt_lookup.py` (see *Helper scripts*) for instant size lookups — it reads the CSV path from `argv[1]` and query paths from stdin. Test it: pipe a known path and confirm a non-zero size.

**Whole-drive outlier discovery is mandatory when a CSV is available.** Run the
committed finder once and retain its output for the classification pass after
the category scans:

```bash
python "$CLEANUP_SCRIPTS/find_outliers.py" /tmp/agentic-cleanup/wiztree.csv \
  --minimum-mb 100 --limit 100 > /tmp/agentic-cleanup/outliers.txt
```

The helper emits non-overlapping large-path hotspots sorted by size. Its output
is read-only evidence and must never be used as a deletion list. It suppresses
`hiberfil.sys` at source. Do not re-add that file by manually inspecting or
sorting the raw CSV.

**Using WizTree data in categories:** When WizTree data is available, replace all PowerShell `Get-ChildItem -Recurse` size measurements with:

```bash
echo "C:\path\to\directory" | python "$CLEANUP_SCRIPTS/wt_lookup.py" /tmp/agentic-cleanup/wiztree.csv
```

Output: `sizeMB|path`

You can pipe multiple paths at once (one per line) for batch lookups. This turns a multi-minute scan phase into seconds.

**Piping paths:** Use `printf '%s\n'` to pipe multiple Windows paths to `wt_lookup.py`. Do NOT use heredocs with Windows backslash paths — they cause bash syntax errors:

```bash
# CORRECT:
printf '%s\n' \
'C:\Users\temaz\AppData\Roaming\Slack\Cache' \
'C:\Users\temaz\AppData\Roaming\Linear\Cache' \
| python "$CLEANUP_SCRIPTS/wt_lookup.py" /tmp/agentic-cleanup/wiztree.csv

# WRONG — heredocs with backslash paths cause syntax errors:
# cat << 'EOF' | python ...
```

**If neither WizTree nor a CSV is available**, fall back to the PowerShell approach described in each category below (marked as "Fallback:").

Also approximate the outlier pass with scoped top-consumer scans. Do not launch
an unbounded recursive whole-drive walk: inspect the largest immediate children
of the user profile, workspace, `%LOCALAPPDATA%`, `%APPDATA%`, and `%TEMP%`, then
drill into material branches until the source is recognizable. On macOS/Linux,
apply the same bounded drill-down with `du -x -d 1` (or `du -x --max-depth=1`)
starting from `/`, the home directory, the workspace, and the platform cache
roots. Record that this is a scoped approximation rather than a complete
indexed-drive census.

### Step 3: Scan All Categories

On macOS, first use the single committed discovery adapter above. Dispatch only
uncovered tool-native categories separately; do not repeat its filesystem walks
with parallel ad-hoc category scripts.

Scan all applicable categories below **in a single batch of parallel tool calls** — one Bash invocation per category, all dispatched in the same assistant turn. This is dramatically faster than sequential scanning (a 30-second category and a 5-second category finish in 30 seconds total, not 35). Skip categories that don't apply to the current platform or where required tools are missing.

**Progress reporting:** Parallel tool calls return as one batch, so per-category live progress is not achievable in this harness. Before dispatching the batch, emit a single line listing the categories being scanned (e.g. "Scanning 9 categories: node_modules, npm cache, app caches, …"). After the batch completes, proceed directly to the report in Step 4. Do not promise streaming progress that the runtime can't deliver.

**Don't dispatch slow scans twice.** If a category's scan command exceeds ~60 seconds (large filesystem walks, heavy `du` recursion), prefer running it once and parsing structured output over running multiple smaller commands — the parallel batch only helps if no single category dominates the wall clock.

**When WizTree data is available**, batch all size lookups for a category into a single `wt_lookup.py` call instead of running individual PowerShell scripts. This is dramatically faster.

---

### First-scan runtime and cache inventory

For ordinary cleanup and `--dry-run`, complete this bounded inventory before the
first report, alongside the category batch. A short cache table is not a complete
scan when material versioned installations or legacy stores remain unexamined.
Keep narrow personal audits and `--structured-preview` within their stated scope.

**Find siblings, not just active paths.** Use indexed evidence to identify
versioned tool installations and cache-store roots, then enumerate immediate
release families and store generations. Without an index, probe known exact tool
roots and metadata from installed managers; do not recursively search the user
profile. For example:

- On Windows, probe `~/.codex/packages/<family>/releases` and inspect the family's
  `current` and `auto-update-version` selectors. Inspect every immediate family,
  not just `standalone`; daemon and standalone installations can select different
  current versions. Read selector metadata without traversing aliases, then
  measure only exact physical release directories within the same family.
- Probe `~/.local/share/claude/versions` through the existing Claude recipe;
  releases can be executable files rather than directories.
- For pnpm, enumerate the store-generation siblings described below rather than
  reporting only `pnpm store path`. Apply the same principle to other discovered
  managers with versioned stores. Do not assume the Windows runtime layouts exist
  on Unix; use the index or that platform's installed-manager metadata.

**Establish the owner before offering removal.** Keep current, newest, pinned and
live versions, even when a selector points to an older installed version. Compare
versions semantically, not by directory timestamp or lexical order. Check known
user/project configuration, registered MCP ownership, fresh process paths and the
owner's installer/update lock. A persistent lock file alone does not prove an
update is active. If selector parsing, locking or ownership checks are unavailable,
report the exact finding as human-review, not a cleanup option. Do not run a
launcher that can auto-update/install merely to learn its version; prefer
allowlisted control metadata. Never print configuration bodies or command lines.

**Measure exact scopes.** Use indexed logical/allocation evidence for discovery.
For Windows candidates, use committed `file_audit.py --root <exact-release-or-store>`
or its metadata API to inspect file identities and hardlink counts without reading
file data. Supply only physical roots, not `current` aliases. Preserve current
selector roots and siblings; disclose budgets, skipped paths and unknown shared
allocation. On other platforms use equivalent bounded, no-follow metadata checks.
Size or lack of a process reference alone is not proof that removal is safe.

**Report in the first pass.** Show qualified exact runtime releases and legacy
stores in **Expanded audit**, with family/generation, current/newest versions kept,
logical and allocated sizes, sharing/ownership evidence and the re-download or
rollback consequence. These items are not included in `all`; require explicit
per-item selection. Existing maintained categories retain their existing selection
rules. Unknown, live and OS/vendor-managed installations remain informational;
this inventory does not authorize uninstalling tools or deleting system runtimes.

**Refresh only approved paths.** Immediately before an approved operation, repeat
the selector, newest/pinned version, ownership, update-lock, link and live-path
checks. Preserve changed/fresh or newly active releases. For legacy Windows lists,
build the exact list first, capture `live_paths.ps1` in a separate invocation that
does not name deletion targets, then run `assert_list.py` with required buckets
and current/newest/sibling exclusions before the committed removal worker.
Measure free space immediately before each operation and verify retained selectors
and versions afterward. Never replace an absent approved path with another version.

---

### Cross-platform categories

These run on every OS. Each category's measurement and cleanup logic branches on platform internally.

---

#### Category: node_modules (Inactive Projects)

**All platforms.** Requires workspace root from Step 2.

**With a WizTree CSV, enumerate instantly with the committed finder:** `python "$CLEANUP_SCRIPTS/find_targets.py" /tmp/agentic-cleanup/wiztree.csv "$WORKSPACE_ROOT"`. The `nm|<mb>|<path>` lines are the candidates — already **top-level** and ≥10 MB, so no filesystem walk and no per-path size lookup needed (the `artifact:<name>|<mb>|<path>` lines feed the Build Artifacts category). Without a CSV, fall back to a filesystem walk for top-level `node_modules` directories under the workspace root.

For each candidate:

1. Get the parent project directory
2. Check inactivity. The `node_modules` may sit inside a subpackage of a monorepo whose `.git` lives further up (e.g. `repo/server/node_modules` with `.git` at `repo/`), so walk up before testing:
   - If `command -v git` fails (git not installed) → treat all as inactive
   - Resolve the repo root: `repo_root=$(git -C <project> rev-parse --show-toplevel 2>/dev/null)`
   - If that returns empty (no `.git` anywhere up the tree) → inactive
   - If `git -C "$repo_root" log -1 --since="4 weeks ago" --oneline` returns empty → inactive
   - Otherwise → active (skip it)
   - **Do NOT** test against `<project>` directly — `git -C <subpackage> log` silently fails when `.git` is one level up and the project gets treated as inactive (false positive).
3. Measure `node_modules` size:
   - **With WizTree:** Pipe path to `wt_lookup.py`
   - **Fallback Windows:** PowerShell `Get-ChildItem` with `-Recurse -File | Measure-Object -Property Length -Sum`
   - **macOS/Linux:** `du -sm <path>/node_modules | cut -f1` (size in MB)
4. Skip if size < 10 MB
5. **Skip if it backs a registered MCP server.** A project can have no recent git activity yet still need its dependencies whenever a static Claude Code or OpenCode V2 local server points into that project. The structured preview uses `registered_mcp.ps1` and refreshes ownership before execution. The legacy `find_targets.py` filter covers only its historical `~/.claude.json` shape, so ordinary legacy scans must not claim equivalent OpenCode coverage. (Two book-power MCPs broke with `-32000` after a cleanup wiped their deps, 2026-06-29.)

Only report **top-level** `node_modules` per project (not nested ones inside `node_modules/`).

Collect: project name, size, full path.

---

#### Category: Package Manager Caches

**All platforms.** Check each tool individually — skip any that aren't installed.

**npm:**
- Check: `command -v npm`
- Cache root: **Windows:** `~/AppData/Local/npm-cache`, **macOS/Linux:** `~/.npm`
- Measure `_cacache` separately from `_npx`. `npm cache clean --force` is the maintained cleanup for `_cacache` and must remain the default.
- Inspect each immediate child of `_npx` as a separate candidate. Include only entries whose newest descendant write is older than 7 days. An empty entry uses the directory's own timestamp.
- **Before reporting and again immediately before deletion, apply the live-path veto to each exact `_npx` child.** On Windows use `live_paths.ps1` plus `assert_list.py --live`; on macOS/Linux inspect process command lines/open files. Any entry containing code used by a running process is protected. Never delete `_npx` itself or pass the npm cache root to `scrub.ps1`.
- Stale `_npx` entries are regenerable: a future `npx` invocation downloads them again. Report their count and size separately so the user sees the redownload consequence.
- Reclaimable npm bytes are `_cacache` plus eligible stale `_npx` children only. Treat every other `_npx` byte as protected and exclude it from the category total.
- **With WizTree:** Pipe `_cacache` and the eligible exact `_npx` child paths to `wt_lookup.py`.
- **Fallback:** PowerShell or `du -sm`
- Clean commands: `npm cache clean --force` for `_cacache`; remove only the individually validated stale `_npx` child directories selected in the category.

**pnpm:**
- Check: `command -v pnpm`
- Resolve the active store with `pnpm store path`, using a context that does not
  trigger project-pinned tool installation. Inventory every immediate versioned
  store under each discovered store root (for example `v3` alongside `v10`), not
  just the generation returned by the command. Probe additional roots only when
  identified by the index or installed-manager metadata; disclose coverage limits.
- A different active path does not establish that a sibling generation is unused.
  Check project `packageManager` pins, `.modules.yaml` store references, explicit
  store configuration, registered consumers, processes and file sharing. Read only
  allowlisted fields and state directory/depth/time bounds and skipped links.
- Measure each generation separately (WizTree or bounded metadata fallback).
  Distinguish logical bytes, allocated bytes and estimated unique recovery;
  inspect hardlinks before treating cache size as recoverable space. Never propose
  removing linked project files or active dependencies to improve the estimate.
- Use `pnpm store prune` for the active store. It does not clean a legacy sibling;
  do not claim otherwise or redirect the current pnpm version into an older
  format without verified compatibility. See https://pnpm.io/cli/store.
- Qualified legacy generations belong in Expanded audit with exact paths and
  explicit per-item selection. On approval, clean contents only of the exact old
  generation, preserve its root, active store and installed dependencies, and
  refresh ownership/liveness/sharing first. Warn that future installs may need to
  re-download packages and offline cache reuse will be lost. Uncertain generations
  remain human-review rather than deletion options.

**yarn:**
- Check: `command -v yarn`
- Detect version: `yarn --version` — if starts with `1.` → Classic, otherwise → Berry
- Classic (v1): `yarn cache dir` → measure. Clean: `yarn cache clean`
- Berry (v2+): Uses per-project `.yarn/cache`. Clean: `yarn cache clean --all`

Collect: tool name, cache path, size for each installed tool. Sum total.

---

#### Category: pip Cache

**All platforms.** Skip if neither `pip` nor `pip3` is installed (`command -v pip || command -v pip3`).

- Run `pip cache info` (or `pip3 cache info`) — parse the "Location" and total size
- Clean command: `pip cache purge` (or `pip3 cache purge`)

Collect: cache size.

---

#### Category: Claude Code Debris

**All platforms.**

Measure sizes of these generated-data directories:
- `~/.claude/debug/`
- `~/.claude/telemetry/`

Use WizTree lookup or fallback PowerShell/du for sizes.

Conversation/session logs and file-edit history are **not debris**. Do not offer
`~/.claude/projects/*/*.jsonl` or `~/.claude/file-history/` for cleanup, regardless
of age. Diagnostic logs must be distinguished from these protected records.

Also scan these bounded Claude-generated targets:

- **MCP diagnostic logs:** Windows
  `%LOCALAPPDATA%\claude-cli-nodejs\Cache\*\mcp-logs-*`; macOS/Linux
  `~/.cache/claude-cli-nodejs/*/mcp-logs-*`. Match only directories whose basename
  starts with `mcp-logs-`; never offer the workspace cache parent. Include only
  logs whose newest write is older than 24 hours, and reapply the live-path veto
  before deletion. These contain diagnostics, not conversations or settings.
- **Superseded Claude binaries:** `~/.local/share/claude/versions/<semver>`.
  Resolve the running version with `claude --version` and require an exact
  matching version entry (file or directory). Keep that exact entry and also keep
  the newest installed version. If the command is missing, parsing fails, or no
  entry matches, report the bounded inventory as human-review rather than hiding
  it or offering removal. Apply the live-path veto to each older entry before
  reporting and immediately before deletion.

**SAFETY — NEVER touch any of the following:**
- `~/.claude/projects/*/memory/` (persistent memories)
- `~/.claude/commands/` (slash commands)
- `~/.claude/skills/` (skills)
- `~/.claude/settings*.json` (settings)
- `~/.claude/history.jsonl` (conversation history)
- `~/.claude/projects/*/*.jsonl` (conversation/session logs, including old logs)
- `~/.claude/file-history/` (file-edit history)

Collect: breakdown (debug X MB, telemetry Z MB, MCP diagnostics M MB,
superseded versions V MB), total size. Exclude protected history from totals.

---

#### Category: Downloaded Model Caches

**All platforms.** Probe the Hugging Face cache at `~/.cache/huggingface`.
Include it only when it exists and is at least 100 MB.

This is downloaded model data, not user-authored model output. Deleting it means
the model must be downloaded again before the dependent application can run.
Before reporting and again before deletion, skip the cache if any running
process has an executable, command line, or open path beneath it, or explicitly
references Hugging Face, Transformers, faster-whisper, or a model stored there.
On Windows, use `live_paths.ps1` and `assert_list.py --live` for the path veto;
the process-name/command-line check is an additional guard, not a substitute.
Restrict keyword inspection to plausible model hosts such as
`python`/`pythonw`, `node`, `bun`, `uv`, or a known model application, and
exclude the probe's own process and launcher ancestors. Never search every
process command line for the keywords: the scanner command itself contains them
and otherwise self-matches as a fake live model.

Measure with WizTree or the platform fallback. Clean only the cache directory's
contents; never broaden the target to `~/.cache`.

Collect: total size and exact path.

---

#### Category: Browser Automation Downloads

**All platforms.** Browser-test tools download full browser distributions that
are regenerated on demand. Probe these exact roots:

| Tool | Windows | macOS | Linux |
|------|---------|-------|-------|
| Playwright | `%LOCALAPPDATA%\ms-playwright` | `~/Library/Caches/ms-playwright` | `~/.cache/ms-playwright` |
| Puppeteer | `~/.cache/puppeteer` | `~/.cache/puppeteer` | `~/.cache/puppeteer` |

Measure each root and list its immediate browser/version children. Skip a tool
under 50 MB. Before reporting and again before deletion, apply the live-path
veto to the exact tool root; if a test runner or browser executable is using a
descendant, protect the entire root. Deletion means Playwright or Puppeteer will
download the required browser again on next use.

Clean only the selected tool root's contents. Never infer sibling cache roots
from the parent directory.

Collect: tool, total size, browser/version children, and exact path.

---

#### Category: Crash Dumps and Kernel Reports

**Platform-specific paths:**
- **Windows:** `~/AppData/Local/CrashDumps/` AND `C:\Windows\LiveKernelReports\`
- **macOS:** `~/Library/Logs/DiagnosticReports/`
- **Linux:** `/var/crash/` and `~/.local/share/apport/`

Check if each directory exists. Measure total size (WizTree or fallback).

`LiveKernelReports` can contain multi-GB kernel watchdog dumps (e.g., `DripsWatchdog-*.dmp`). These are safe to delete.

Skip if total size < 5 MB.

Clean command: For `CrashDumps`, `rm -rf <path>/*`. For `LiveKernelReports`, requires elevated PowerShell: `Remove-Item "C:\Windows\LiveKernelReports\*" -Recurse -Force`.

Collect: file count, total size, paths, breakdown by location.

---

#### Category: Build Artifacts (Inactive Projects)

**All platforms.** Requires workspace root from Step 2.

Use the **same inactivity check** as the node_modules category (no git commits in 4 weeks, or no `.git` directory).

**Then apply a build-freshness guard — git inactivity does NOT mean the artifact is cold.** Before flagging any artifact dir, check the newest file inside it and **skip the dir if anything was modified in the last 24 hours**. A project with no commits in a month can still be mid-build *right now*: another Claude Code session, a file watcher, or a running dev server writes into `.next`/`.vite` continuously without ever touching git. The git check answers "is anyone developing this?"; it cannot answer "is anyone building this?" — and only the second question matters for a build dir.

- **macOS/Linux:** `find <dir> -mtime -1 -print -quit 2>/dev/null | grep -q .` — bail on first hit, don't traverse the whole tree.
- **Windows:** `(Get-ChildItem <dir> -Recurse -File -EA SilentlyContinue | Measure-Object LastWriteTime -Maximum).Maximum` — skip if within 24h.
- **With a WizTree CSV:** the CSV carries a modified timestamp per row — read it from there rather than re-walking the tree.

Report skipped-as-fresh dirs in the scan output (`<path> — SKIPPED, built <N> min ago`) rather than dropping them silently, so a surprising skip is visible rather than looking like the dir doesn't exist.

**Do not override this guard by reasoning that the artifact is "just a regenerable cache."** That rationalisation is the failure mode, not an exception to the rule: regenerating it out from under a running build is precisely the damage. Observed 2026-07-16 — a 1.4 GB `.next` was flagged INACTIVE by the git check and offered for deletion while another agent's build was 11 minutes old; 1,250 of its 1,279 files had been written minutes earlier. Same failure class as the live-MCP-server rule in the node_modules category: **a git-cold project can hold red-hot files.**

**With a WizTree CSV**, the `artifact:<name>|<mb>|<path>` lines emitted by `find_targets.py` (run once in the node_modules category) already list every `.next`/`.turbo`/`.parcel-cache`/`.vite` dir ≥10 MB under the workspace — just keep the ones whose project is inactive **and pass the freshness guard above**. Otherwise scan inactive projects for these directories:
- `.next/`
- `.turbo/`
- `.parcel-cache/`
- `.vite/`

Handle `dist/` separately (the finder omits it): include **ONLY if `dist` appears in the project's `.gitignore` file.** Many projects commit `dist/` as published output. Never delete committed `dist/` directories.

Measure each found artifact directory (WizTree or fallback).

Collect: project name, artifact type, size, full path.

---

#### Category: Docker

**All platforms.** Skip if Docker is not installed or daemon is not running.

- Check: `command -v docker` — skip if fails
- Check: `docker info > /dev/null 2>&1` — skip if fails (daemon not running)
- Run: `docker system df` — parse reclaimable space for Images and Build Cache
- Clean commands: `docker image prune -f` (dangling images) and `docker builder prune -f` (build cache)
- Do **NOT** use `docker system prune` — it also removes stopped containers

Collect: dangling images size, build cache size, total.

---

### Windows-only categories

Skipped on Linux/macOS. Several require elevated privileges — see Step 6 for trusted-worker handling.

---

#### Category: Squirrel Old Versions (Windows only)

**Skip if platform is not windows.**

Electron apps on Windows use the Squirrel updater, which keeps old versions in `~/AppData/Local/<app>/app-*` directories.

Run the committed `squirrel.ps1` (see *Helper scripts*) to discover old `app-*` directories — `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/squirrel.ps1")"` — output lines are `<app>|<oldVersionDir>|<fullPath>`. Then measure sizes:
- **With WizTree:** Pipe all discovered paths to `wt_lookup.py`
- **Fallback:** Use PowerShell `Get-ChildItem -Recurse -File | Measure-Object -Property Length -Sum` per directory

Skip entries < 5 MB.

Collect: app names, old version names, sizes, and full paths (needed for deletion).

---

#### Category: Windows.old (Windows only)

**Skip if platform is not windows.**

Check if `C:\Windows.old` exists. Measure size (WizTree or fallback PowerShell).

Skip if size is 0.

**IMPORTANT:** This category requires elevated privileges to delete. During cleanup (Step 6), warn the user that Windows.old must be removed via Settings > System > Storage > Temporary files > Previous Windows installation(s), or via Disk Cleanup run as Administrator. Do NOT attempt `rm -rf` — it will fail with permission errors.

Collect: size.

---

#### Category: Delivery Optimization Cache (Windows only)

**Skip if platform is not windows.**

Measure: `C:\ProgramData\Microsoft\Windows\DeliveryOptimization` (WizTree or fallback PowerShell).

Skip if size < 50 MB.

Cleanup (Step 6): supported Settings > System > Storage > Temporary files >
Delivery Optimization Files. Do not implicitly stop services or delete live
system cache trees to bypass access restrictions.

**Note:** Requires elevated privileges. If cleanup fails with access denied, inform the user to run via Settings > System > Storage > Temporary files > Delivery Optimization Files.

Collect: size.

---

#### Category: Windows Temp Files (Windows only)

**Skip if platform is not windows.**

Measure `%TEMP%` and `C:\Windows\Temp` (WizTree or fallback PowerShell).

Skip if total < 50 MB.

Clean command (Step 6): Exclude **four** runtime and cleanup subdirectories. Files locked by running processes will be skipped automatically:

* `agentic-cleanup` — this run's scratch (holds the ~200 MB WizTree CSV).
* `claude-cleanup` — a pre-rename cleanup run's scratch; preserve it while older installed sessions may still be active.
* `claude` — **Claude Code's own scratch.** `%TEMP%\claude\<project-hash>\` holds the live session's task-output files and scratchpad. Deleting it kills in-flight commands: the running Bash tool's output file disappears and the call dies with `output file could not be read (ENOENT)`. Observed 2026-07-16 — it survived only because the harness had it open, so `scrub.ps1` returned `FAIL: Access to the path is denied`. Do not rely on that lock; exclude it by name.
* `opencode` — **OpenCode's own scratch.** `%TEMP%\opencode\` may hold live tool output and task state for the current session; deleting it can destroy in-flight work.

```powershell
Get-ChildItem "$env:TEMP" -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('agentic-cleanup','claude-cleanup','claude','opencode') } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
```

Collect: total size, breakdown (user temp X MB, system temp Y MB).

---

#### Category: Browser Caches (Windows only)

**Skip if platform is not windows.**

Measure browser cache directories for installed browsers. Check these paths:

- Chrome: `%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache`, `...\Code Cache`
- Edge: `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache`, `...\Code Cache`
- Brave: `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache`
- Firefox: `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2`

**With WizTree:** Pipe all paths to `wt_lookup.py` in one batch call.
**Fallback:** Use PowerShell `Get-ChildItem -Recurse` per path.

Group by browser name (sum sizes if multiple paths per browser). Skip if total across all browsers < 50 MB.

**IMPORTANT:** Warn the user to close browsers before cleaning for best results. Files locked by running browsers will be skipped automatically.

Clean command (Step 6): `rm -rf <each cache directory path>/*` (delete contents, not the directory itself — browsers recreate it).

Collect: browser names, sizes, paths.

---

#### Category: Electron App Caches (Windows only)

**Skip if platform is not windows.**

Electron apps store caches in `%APPDATA%/<AppName>/` and `%LOCALAPPDATA%/<AppName>/`. Scan for `Cache/`, `Code Cache/`, `GPUCache/`, and `Service Worker/CacheStorage/` subdirectories inside these app directories:

- Claude Desktop (`%APPDATA%\Claude`)
- Miro (`%APPDATA%\RealtimeBoard`)
- Slack (`%APPDATA%\Slack`)
- Discord (`%APPDATA%\discord`)
- Linear (`%APPDATA%\Linear`)
- Notion (`%APPDATA%\Notion`)
- Notion Calendar (`%APPDATA%\Notion Calendar`)
- Signal (`%APPDATA%\Signal`)
- Element (`%APPDATA%\Element`)
- Figma (`%APPDATA%\Figma`)
- Zoom (`%APPDATA%\Zoom`)
- Telegram (`%APPDATA%\Telegram Desktop`)
- Tana (`%LOCALAPPDATA%\tana`)
- TogglTrack (`%LOCALAPPDATA%\TogglTrack`)

For each installed app, discover cache subdirectories (PowerShell `Get-ChildItem -Directory -Filter <cacheName> -Recurse -Depth 2`), then measure sizes:

Zoom is a named exception to the generic Electron cache names: probe
`%APPDATA%\Zoom\data\WebviewCacheX64` directly and include only its contents.
Never broaden this target to `%APPDATA%\Zoom\data` or the Zoom profile root.
If any Zoom process is running, classify this item as close-application-first
and do not clean it until a refreshed process check confirms Zoom is closed.

- **With WizTree:** Pipe all discovered cache paths to `wt_lookup.py`
- **Fallback:** PowerShell `Get-ChildItem -Recurse`

Skip apps with < 10 MB of caches. Skip category if total < 50 MB.

**IMPORTANT:** Warn the user to close the affected apps before cleaning for best results.

Clean command (Step 6): `rm -rf <each cache directory path>/*` (contents only).

Collect: app names, sizes, paths.

---

#### Category: Stale Updater Files (Windows only)

**Skip if platform is not windows.**

Electron apps using Squirrel or similar updaters keep downloaded update packages after they've been applied.

Check these paths:
- `%LOCALAPPDATA%\@lineardesktop-updater\pending`
- `%LOCALAPPDATA%\notion-updater\pending`
- `%APPDATA%\uTorrent\updates`
- `%APPDATA%\Signal\update-cache`

Also scan Squirrel apps (`%LOCALAPPDATA%\<app>\packages\`) for old `.nupkg` files — keep only the newest, measure the rest.

Measure sizes (WizTree or fallback PowerShell).

Skip if total < 20 MB.

Clean command (Step 6): `rm -rf <each path>/*` for directories, or `rm -f <path>` for individual .nupkg files.

Collect: app names, sizes, paths.

---

#### Category: Windows System Logs (Windows only)

**Skip if platform is not windows.**

Windows accumulates rotated log files; current diagnostics are protected:

- `C:\Windows\Logs\CBS\` — Component-Based Servicing logs (can grow to 500+ MB)
- `C:\ProgramData\Comms\PCManager\log\` — OEM PC Manager logs (Huawei, Lenovo, etc.)

Use committed `maintenance.ps1 -Action ScanLogs -OutputPath <new-evidence>`.
It lists only exact rotated files older than seven days, preserves CBS.log,
DISM.log and the newest PC Manager log per directory, and records coverage.
Report selected logical sizes, not whole-root totals, using the configured
materiality threshold (default 50 MiB).

Clean command (Step 6): from an already elevated trusted worker, run
`maintenance.ps1 -Action CleanLogs -EvidencePath <selected-evidence> -Approved
-OutputPath <new-result>`. Selection, age, metadata, containment, liveness and
locks are rechecked for every file. No wildcard deletion, root removal, killing
holders, or blanket retry is allowed. Inspect the worker-owned structured result.

Collect: exact files, logical sizes, protected/skipped coverage and result statuses.

---

#### Category: VS Package Cache (Windows only)

**Skip if platform is not windows.**

Visual Studio stores downloaded installer packages in `C:\ProgramData\Microsoft\VisualStudio\Packages\`. This cache can grow to several GB and is safe to clean — VS will re-download packages if needed for modifications or repairs.

Measure size (WizTree or fallback PowerShell). Skip if path doesn't exist or size < 100 MB.

Clean command (Step 6): Requires elevated PowerShell:
```powershell
Remove-Item "$env:ProgramData\Microsoft\VisualStudio\Packages\*" -Recurse -Force -ErrorAction SilentlyContinue
```

**Note:** After cleaning, VS component modifications/repairs will need to re-download packages. This is fine for normal use.

Collect: size.

---

#### Category: WinSxS Component Store (Windows only)

**Skip if platform is not windows.**

The Windows component store (`C:\Windows\WinSxS`) accumulates **superseded** update components — old package versions kept as rollback backups after Windows Updates. `StartComponentCleanup` removes them safely (Microsoft-supported); it never touches in-use components.

Raw `C:\Windows\WinSxS` and backups/disabled-features sizes include live and
hardlinked data and are **not** recovery estimates. DISM gives package counts
and a recommended flag, not guaranteed recoverable bytes. Use committed
`maintenance.ps1 -Action Analyze -OutputPath <new-evidence>` from an already
elevated trusted worker:

```
dism.exe /Online /English /Cleanup-Image /AnalyzeComponentStore /NoRestart
```

Report "Number of Reclaimable Packages" and "Component Store Cleanup Recommended"
with unknown recovery bytes. Skip cleanup if Recommended is No or packages is 0.
The committed worker owns its result; do not read raw DISM/log diagnostics into
the conversation. Missing output is unknown, not proof of UAC cancellation.

Clean command (Step 6): **Elevated.** `maintenance.ps1 -Action Components
-EvidencePath <recent-analysis> -Approved -OutputPath <new-result>`. The worker
checks pending reboot/installer state, waits boundedly for servicing workers to
exit naturally, reuses only fresh verified analysis, and invokes one supported
`dism.exe /Online /English /Cleanup-Image /StartComponentCleanup /NoRestart` pass.
No `/ResetBase`, reboot, process/service stopping, or automatic second pass.

Collect: native exit status, analysis status, remaining package count, recommended
flag and signed before/after net disk change. Do not infer bytes from package count.

---

#### Category: Config.Msi Leftovers (Windows only)

**Skip if platform is not windows.**

`C:\Config.Msi` holds Windows Installer rollback/transaction data. It is transient during an install, but aborted or large installs leave it behind at multi-GB. Windows recreates it on demand, so a leftover is safe to remove **when no install or update is in progress**.

Measure `C:\Config.Msi` (WizTree or fallback PowerShell). Skip if it does not exist or is < 100 MB.

Clean command (Step 6): **Elevated.** Only an exact selected `C:\Config.Msi`
operation through a policy-approved trusted executor, after installer/liveness
checks. Resolve an inline denial rather than hiding the operation in a script.

Collect: size.

---

#### Category: AppData Remnants (Windows only)

**Skip if platform is not windows.**

When apps are uninstalled, their data directories in `%APPDATA%` and `%LOCALAPPDATA%` often remain. Detect orphaned directories by cross-referencing against installed programs.

Run the committed `appdata_orphans.ps1` (see *Helper scripts*): `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/appdata_orphans.ps1")"`. It emits orphans > 50 MB as `dirName|sizeMB|fullPath`. Add `-Explain` to get a per-directory keep/skip reason on **stderr** (stdout stays parseable) — use it whenever a result looks surprising.

**It applies the same 4-layer filter chain as the Linux orphan scan** (ported 2026-07-16), cheapest first:

1. **Allowlist** — system dirs, the dev-tool surface (`npm-cache`, `pnpm`, `uv`, `node-gyp`, `bun`, `cargo`, …), and **anything that is another category's target**, excluded by construction.
2. **Active binary** — `Get-Command <dirname>` resolves ⇒ live tool on PATH.
3. **Package match** — registry DisplayName at a **token boundary**, never substring, after normalising the dir name (strip a leading `@`, strip `-updater`/`-helper`/`-cache` suffixes, apply the alias map). Plus a **liberal prefix rule**: Windows DisplayNames append the version (`Linear 1.29.5`), so the first token is the app name and `lineardesktop` → `linear` is a correct skip. Direction is `dir.StartsWith(pkg)`, so the Linux `zenity`-swallows-`zen` case can't occur.
4. **Recent activity** — any file modified in 30 days ⇒ not abandoned. Bails on first hit.

**Errors here are not symmetric — bias toward skipping.** A false positive offers live data for deletion and trains the user to click through the per-item confirmation that is their only protection; a false negative merely leaves disk unreclaimed. When unsure, skip.

**With WizTree:** Instead of measuring each directory with `Get-ChildItem`, pipe discovered orphan paths to `wt_lookup.py`.

Parse output. Each line is: `dirName|sizeMB|fullPath`

Skip if no orphans found or total < 100 MB. **Zero orphans is a normal, healthy result** — this scan reported 0 on a 40-project workstation after the port. Do not loosen the filters to make the category produce rows.

**IMPORTANT:** This category requires user confirmation per-item during cleanup. Present the list of detected orphans and let the user confirm which to delete — false positives are possible (portable apps, manually installed tools). Never auto-delete orphaned AppData directories.

*Why the chain exists* (2026-07-16): before the port this scan had **one** layer — an exact-match skiplist plus a substring registry test — and every hit was wrong. `npm-cache` (1058 MB), `pnpm`, `uv`, `node-gyp`, `RealtimeBoard` (Miro, installed and running) and `CrashDumps` — **6 of 6 false positives**. The skiplist held `npm` and `node.js`, but the test was `-eq`, so `npm-cache` and `node-gyp` sailed straight through. Sharpest of all: it offered `npm-cache`, the one directory the `_npx` rule says must never be whole-dir deleted. A category where every row is wrong is worse than no category — the per-item confirmation that "saves" it is exactly what it erodes.

Clean command (Step 6): `rm -rf <each confirmed orphan path>` — only after user confirms the specific items.

Collect: directory names, sizes, paths.

---

#### Category: Windows SDK Old Versions (Windows only)

**Skip if platform is not windows.**

Windows SDK installs multiple versions side-by-side in `C:\Program Files (x86)\Windows Kits\10\`. Each version includes Lib, Include, and bin directories that can be 500 MB+.

Run the committed `winsdk.ps1` (see *Helper scripts*): `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/winsdk.ps1")"`. It keeps the newest SDK version and emits each older one (summed across `Lib`/`Include`/`bin`, > 50 MB) as `versionNumber|sizeMB|semicolonSeparatedPaths`.

**With WizTree:** Pipe SDK version paths to `wt_lookup.py` instead of `Get-ChildItem`.

Parse output. Each line is: `versionNumber|sizeMB|semicolonSeparatedPaths`

Skip if no old versions found.

**Note:** Only old SDK versions are flagged — the newest version is always kept. Projects pinned to a specific SDK version may break if that version is removed. Report which versions will be deleted so the user can make an informed choice.

Cleanup requires separate explicit uninstall approval and dependency review.
Use the registered Microsoft uninstaller rather than manually deleting SDK
installation directories. Preserve the operating system's Universal CRT.

Collect: version numbers, sizes, paths.

---

#### Category: Orphaned VS Installations (Windows only)

**Skip if platform is not windows.**

Visual Studio installations can become orphaned — directories exist in `C:\Program Files (x86)\Microsoft Visual Studio\` but the VS Installer no longer tracks them.

Run the committed `vs_orphans.ps1` (see *Helper scripts*): `powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/vs_orphans.ps1")"`. It compares VS install dirs against `vswhere` output and emits untracked ones > 100 MB as `displayName|sizeMB|fullPath`.

**With WizTree:** Pipe discovered paths to `wt_lookup.py`.

Parse output. Each line is: `displayName|sizeMB|fullPath`

Skip if no orphans found.

Clean command (Step 6): Requires elevated PowerShell:
```powershell
Remove-Item "<fullPath>" -Recurse -Force -ErrorAction SilentlyContinue
```

Collect: installation names, sizes, paths.

---

### Unix categories (Linux + macOS)

Skipped on Windows. Some categories apply to both Linux and macOS; others target one OS only — see each category's header for which.

---

#### Category: App Caches (macOS + Linux only)

**Skip on Windows** (other Windows-specific categories cover app bloat).

- **macOS:** Scan `~/Library/Caches/` for subdirectories larger than 50 MB
- **Linux:** Scan `~/.cache/` for subdirectories larger than 50 MB

Use `du -sm` to measure each subdirectory. Report only those exceeding 50 MB.

Before offering a cache, establish its owner and exact cache scope. Before any
selected removal, confirm the owner is closed and refresh owner/process and
live-path evidence. Unknown ownership or incomplete evidence stays review-only. Preserve
the selected cache root; never broaden a cache operation to app/profile data.
Open or locked files can still be unlinked on Unix; do not rely on locks or an
expected permission error to protect a running app. Do not close apps, kill
holders or change permissions to make a cache deletable.

Homebrew's resolved cache root and its descendants belong to the manual-only
Homebrew report below, not a second selectable App Caches entry. If ownership of
a default-looking or legacy Homebrew directory is unresolved, keep it review-only;
do not assume it is the active cache or remove it through a generic cache category.

**Self-protection:** On Linux/macOS, the currently-running Claude Code session
caches state in `~/.cache/claude-cli-nodejs/` or the platform equivalent. Treat
the active runtime cache as a live dependency, not a selectable app-cache target.
An explicit category selection does not override liveness protection. Only exact
stale diagnostic subdirectories meeting the Claude debris recipe's independent
freshness and liveness checks can be considered; never clear the workspace parent.

Collect: app/directory name, size, full path.

---

#### Category: System Package Manager Cache (Linux only)

**Skip if platform is not linux.** Detect distro by checking which package manager is installed (`command -v dnf` / `apt-get` / `pacman` / `zypper`). Skip if none match.

Measure (no sudo required for read):
- **dnf (Fedora/RHEL):** `du -sm /var/cache/dnf 2>/dev/null | cut -f1`
- **apt (Debian/Ubuntu):** `du -sm /var/cache/apt/archives 2>/dev/null | cut -f1`
- **pacman (Arch):** `du -sm /var/cache/pacman/pkg 2>/dev/null | cut -f1`
- **zypper (openSUSE):** `du -sm /var/cache/zypp 2>/dev/null | cut -f1`

Skip if size < 100 MB.

Clean command (Step 6): **Requires sudo.** Run in the user's terminal so they can enter their password:
- dnf: `sudo dnf clean all`
- apt: `sudo apt clean`
- pacman: `sudo pacman -Sc --noconfirm` (keeps installed package versions; use `-Scc` to wipe all, but warn it removes recovery cache)
- zypper: `sudo zypper clean --all`

Collect: package manager name, size, path.

---

#### Category: journald Logs (Linux only)

**Skip if platform is not linux.** Skip if `command -v journalctl` fails.

Measure: `journalctl --disk-usage 2>/dev/null` — parse the size from the output (e.g. "Archived and active journals take up 1.4G in the file system.").

Skip if size < 200 MB.

Clean command (Step 6): **Requires sudo for system journals.** Default to a 30-day window so the user keeps recent boot history:
- `sudo journalctl --vacuum-time=30d`

Alternative if the user wants a hard size cap: `sudo journalctl --vacuum-size=200M`.

Collect: current disk usage, suggested target.

---

#### Category: Flatpak Unused Runtimes (Linux only)

**Skip if platform is not linux.** Skip if `command -v flatpak` fails.

Detect candidates: `flatpak uninstall --unused --dry-run 2>/dev/null` — parse the listed runtimes. Flatpak doesn't print sizes in the dry-run output, so measure separately:

```bash
flatpak uninstall --unused --dry-run 2>/dev/null | grep -oP '^\s+\d+\.\s+\K[^\s]+' | while read ref; do
  # Each runtime is at ~/.local/share/flatpak/runtime/<id>/<arch>/<branch>
  # or /var/lib/flatpak/runtime/... for system installs
  echo "$ref"
done
```

Sum sizes via `du -sm ~/.local/share/flatpak/runtime/<ref-path> 2>/dev/null` and `du -sm /var/lib/flatpak/runtime/<ref-path> 2>/dev/null` per ref.

Skip if total < 200 MB or no unused runtimes.

Clean command (Step 6): `flatpak uninstall --unused -y` (system installs prompt for sudo).

Collect: runtime list, total size.

---

#### Category: Old Kernels (Linux only)

**Skip if platform is not linux.**

- **Fedora/RHEL (dnf):** Check installed kernel count: `rpm -q kernel-core | wc -l`. If > 2, old kernels can be removed. Measure: `rpm -q kernel-core --queryformat '%{SIZE}\n' | sort -n | head -n -1 | awk '{s+=$(1)} END {print int(s/1048576)}'` (sum size of all but the newest, in MB).
- **Debian/Ubuntu (apt):** `dpkg -l 'linux-image-*' | grep '^ii' | wc -l`. Use `apt autoremove --dry-run` to list candidates and parse the freed-disk line.

Skip if only one kernel installed, or total < 200 MB.

Clean command (Step 6): **Requires sudo.**
- Fedora/RHEL: `sudo dnf remove $(dnf repoquery --installonly --latest-limit=-1 -q)` — removes all but the newest. Alternatively, set `installonly_limit=2` in `/etc/dnf/dnf.conf` for future autoprune.
- Debian/Ubuntu: `sudo apt autoremove --purge`

**Warning to display:** Always keep at least 2 kernels (current + previous) in case the newest fails to boot. The commands above preserve the latest; double-check before running.

Collect: kernel count, size to reclaim.

---

#### Category: Trash (Linux + macOS)

**Skip on Windows.**

- **Linux:** Measure `~/.local/share/Trash` (XDG standard). Also check secondary trash dirs on other mounted filesystems: `find /media /mnt -maxdepth 3 -type d -name ".Trash-$(id -u)" 2>/dev/null`.
- **macOS:** Measure `~/.Trash` and per-volume `.Trashes/$(id -u)` on mounted volumes.

Use `du -sm` per path. Sum total.

Skip if total < 50 MB.

Clean command (Step 6):
- Linux primary: `find ~/.local/share/Trash -mindepth 1 -delete` (re-create empty `files/` and `info/` subdirs after: `mkdir -p ~/.local/share/Trash/files ~/.local/share/Trash/info`).
- macOS primary: `find ~/.Trash -mindepth 1 -delete`.
- Per-volume trashes: same `find … -mindepth 1 -delete` pattern.

Confirm with the user before clearing — Trash is often the "I'll restore that later" pile.

Collect: trash paths, sizes.

---

#### Category: Dev Tool Caches (Linux + macOS)

**Skip on Windows** (Windows-side dev tooling lives in different paths and is usually small enough to ignore).

Many language toolchains hoard caches outside `~/.cache/` and don't show up in `pip cache info`-style commands. Probe each tool individually — only include in the report if the cache exists AND is ≥ 50 MB. Skip the whole category if total < 100 MB.

| Tool | Path | Detection | Notes |
|------|------|-----------|-------|
| Rust (cargo registry) | `~/.cargo/registry` | `command -v cargo` | Re-downloaded on next build |
| Rust (cargo git db) | `~/.cargo/git/db` | `command -v cargo` | Re-cloned on next build |
| Go modules | `~/go/pkg/mod` | `command -v go` or path exists | **Read-only by default** — see clean note below |
| uv | `~/.cache/uv` | `command -v uv` or path exists | Already inside `~/.cache`; named separately for clarity in the report |
| Poetry | `~/.cache/pypoetry` | `command -v poetry` or path exists | Same |
| pip-tools | `~/.cache/pip-tools` | path exists | Same |
| ccache | `~/.ccache` or `~/.cache/ccache` | `command -v ccache` | Check `ccache -s` for current cache size |
| sccache | `~/.cache/sccache` | `command -v sccache` | Rust/C++ cross-compile cache |
| Gradle | `~/.gradle/caches` | path exists | Java; can be 2+ GB |
| Maven | `~/.m2/repository` | `command -v mvn` or path exists | Java; can be 1+ GB |
| Bun | `~/.bun/install/cache` | `command -v bun` | JS |

Measure each via `du -sm <path> 2>/dev/null | cut -f1`. Skip entries < 50 MB.

**Hardlink/CAS caveat — what `du` says vs what `df` reclaims:** Bun and pnpm use content-addressed stores with hardlinks from the cache into each project's `node_modules/`. So does Cargo's git checkout cache to some extent. `du -sm` reports the apparent size from the cache's perspective, but when you delete the cache entries, the underlying disk blocks stay allocated as long as ANY project `node_modules/` still hardlinks to them. Real `df` reclaim only happens when the **last** reference is removed — which typically means cleaning inactive project `node_modules/` in the same run. Flag this in the report when the candidate is Bun, pnpm, or any other tool documented to use hardlinks/CAS — describe the "may not show up in df" caveat so the user isn't surprised. The cleanup is still worthwhile as hygiene (removes stale entries), but pair it with the `node_modules (inactive)` category for actual space recovery.

Collect: per-tool name, path, size.

**Clean commands** (Step 6):
- Cargo: prefer `cargo cache --autoclean` if `cargo-cache` is installed; otherwise `find ~/.cargo/registry -mindepth 1 -delete && find ~/.cargo/git/db -mindepth 1 -delete`
- Go: **`go clean -modcache`** — the standard `find -delete` fails because the module cache is checked out read-only. `go clean` handles permission unlocking.
- uv: `uv cache clean`
- Poetry: `poetry cache clear --all -n .` (older versions) or `rm -rf ~/.cache/pypoetry/cache`
- pip-tools / sccache / Bun caches: `find <path> -mindepth 1 -delete`
- ccache: `ccache -C` (clears) or `ccache --max-size=<n>G` to just cap going forward
- Gradle: `find ~/.gradle/caches -mindepth 1 -delete` — IDEs may need a re-index after
- Maven: `find ~/.m2/repository -mindepth 1 -delete` — re-downloads on next build

---

#### Category: Orphaned Config/Data Dirs (Linux only)

**Skip if platform is not linux.** Linux equivalent of the Windows "AppData Remnants" category.

When apps are uninstalled, their profile/data dirs in `~/.config/` and `~/.local/share/` often stay behind (the Zen Browser case is a textbook example — 50+ MB of profile data with the binary long gone).

**Scan:**
1. Build the installed-app set by combining all available package managers:
   - `rpm -qa --queryformat '%{NAME}\n' 2>/dev/null` (Fedora/RHEL)
   - `dpkg-query -W -f='${Package}\n' 2>/dev/null` (Debian/Ubuntu)
   - `pacman -Qq 2>/dev/null` (Arch)
   - `flatpak list --app --columns=application 2>/dev/null` (Flatpak)
   - `snap list 2>/dev/null | awk 'NR>1 {print $(1)}'` (Snap)
2. For each subdirectory under `~/.config/` and `~/.local/share/`:
   - Skip a curated allowlist of system/desktop-environment dirs that don't belong to a single package: `dconf`, `gtk-2.0`, `gtk-3.0`, `gtk-4.0`, `pulse`, `pipewire`, `wireplumber`, `systemd`, `mimeapps.list`, `user-dirs.dirs`, `autostart`, `fontconfig`, `ibus`, `goa-1.0`, `evolution`, `gnome-*`, `xdg-desktop-portal`, `KDE`, `kdedefaults`, `plasma-*`, `kglobalshortcutsrc`, `flatpak`, `snap`, `recently-used.xbel`, `applications`, `mime`, `icons`, `themes`, `fonts`, `keyrings`, `nautilus`, `Trash`, `RecentDocuments`, `sounds`, `backgrounds`, `desktop-directories`.
   - Skip dirs starting with `.` (hidden inside hidden — never present here, but cheap guard).
   - **Active-binary check:** if `command -v <dirname>` resolves to a path, skip the dir — it belongs to a `curl | sh`–installed tool that's on PATH. Cheap and catches most curl-installed tools (claude, nvm, sdkman, rustup, etc.).
   - **Recent-activity check:** if any file inside the dir has been modified within the last 30 days, skip the dir. Orphaned apps don't get touched; active tools (pnpm, bun, anything writing logs/state) modify their data dirs regularly. This catches tools whose binary lives behind a shell-rc-extended PATH that non-interactive shells don't see (pnpm is the canonical example — its binary is on the user's interactive PATH but not the non-interactive one). Implementation: `find <dir> -mtime -30 -print -quit 2>/dev/null | grep -q .` — bail on first hit, don't traverse the whole tree.
   - **Package-match check (token-boundary, not substring):** lowercase the dir name and test it against the installed-app set. Plain substring matching produces real-world false-negatives — e.g. `zenity` (GTK dialog tool) would swallow `zen` (Zen Browser profile dir) and incorrectly skip a real orphan. Require the dir name to appear at a token boundary in the package name. In bash, that means matching any of: `$pkg == $name` (exact), `$pkg == "$name"-*` (prefix with dash), `$pkg == "$name".*` (prefix with dot, e.g. `kernel.x86_64`), `$pkg == *-"$name"`, `$pkg == *-"$name"-*`, `$pkg == *-"$name".*`. Don't include a reverse-direction "dir name contains package's first token" check — on Linux, package names use `-` and `.` so liberally that the first token is usually overly broad (e.g. `google-chrome-stable` → first token `google` would match any dir starting with `google`).
   - If allowlist + active-binary + recent-activity + package-match all miss → potential orphan.
3. Measure each orphan with `du -sm`. Skip < 50 MB.

Skip the whole category if total < 100 MB or no orphans.

**IMPORTANT:** Require per-item user confirmation during cleanup. False positives are common — portable AppImages, manually-installed binaries from `/opt`, dev tools installed via `curl | sh` that aren't in any package manager. Never auto-delete orphaned dirs.

Clean command (Step 6): `find <orphan_path> -mindepth 1 -delete && rmdir <orphan_path>` per confirmed orphan.

Collect: dir name, location (`~/.config` or `~/.local/share`), size, full path.

---

#### Category: Browser Caches (Linux only)

**Skip if platform is not linux.** Firefox on Linux lives under `~/.cache/mozilla` and is already covered by the App Caches scan; this category targets the Chromium family, which stores its cache under `~/.config/<browser>/` instead of `~/.cache/`.

Probe each browser's path(s) — include only if the directory exists. Each browser may have multiple profiles (`Default`, `Profile 1`, `Profile 2`, …) — sum across all of them.

| Browser | Cache root |
|---------|------------|
| Google Chrome | `~/.config/google-chrome/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Chromium | `~/.config/chromium/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Brave | `~/.config/BraveSoftware/Brave-Browser/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Microsoft Edge | `~/.config/microsoft-edge/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Vivaldi | `~/.config/vivaldi/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Opera | `~/.config/opera/Cache`, `~/.config/opera/Code Cache` |

Discovery pattern (Bash):
```bash
for browser_root in ~/.config/google-chrome ~/.config/chromium ~/.config/BraveSoftware/Brave-Browser ~/.config/microsoft-edge ~/.config/vivaldi ~/.config/opera; do
  [ -d "$browser_root" ] || continue
  # Find all profile dirs (Default, Profile 1, etc.) and sum their Cache/Code Cache/GPUCache
  find "$browser_root" -maxdepth 2 -type d \( -name Cache -o -name "Code Cache" -o -name GPUCache \) 2>/dev/null
done
```

Measure each discovered path with `du -sm`. Group by browser (sum across profiles + cache subtypes). Skip browsers with < 50 MB. Skip the category if total across all browsers < 100 MB.

**IMPORTANT:** The affected browser(s) must be closed before cleaning. Refresh
owner/process and live-path checks before each exact selected cache operation;
incomplete evidence stays review-only. Open or locked files can still be unlinked
on Unix. Do not rely on locks, kill holders or change permissions. Preserve cache
roots and report actual access failures/partial results.

Clean command (Step 6): `find <each cache directory path> -mindepth 1 -delete` per discovered cache dir (preserve the directory itself — the browser recreates it on next launch).

Collect: browser names, total size per browser, paths.

---

#### Category: System Package Manager Cache (macOS only)

**Skip if platform is not macos.** macOS equivalent of the Linux `/var/cache/dnf` etc. category. Detect by checking which package manager is installed.

**Homebrew:**

This is an **informational/manual-only** report, not an automatically executable
cache-cleanup category. Exclude it from the selectable category table and `all`.
[Homebrew's cleanup command](https://docs.brew.sh/Manpage#cleanup-options-formulacask-)
can remove old installed formula versions, stale locks and other maintenance
targets as well as downloads. Scrubbing does not make that operation cache-only,
and downloads for installed formulae/casks can be retained. Cache usage is not an
expected cleanup recovery amount.

**Resolve and measure the actual cache, not the installation prefix.** The
metadata command honors `HOMEBREW_CACHE`; do not override that variable or assume
the default `~/Library/Caches/Homebrew`. Use this read-only probe with a bounded
tool invocation (45 seconds maximum). Links, invalid roots, inaccessible scopes,
nonzero metadata/measurement results and timeouts remain unknown/review-only,
not a fallback to the default path. Do not inspect a separate default `downloads`
directory when the configured cache is elsewhere. Descendant sizes must not be
added to a measured parent total.

```bash
# Homebrew cache discovery (read-only)
set -eu
if ! command -v brew >/dev/null 2>&1; then
  printf 'Homebrew: not installed; skipped\n'
  exit 0
fi
printf 'Homebrew: manual-only; selectable=false; excluded from all\n'
printf 'Reclaimable bytes: unknown (cache usage is not cleanup scope)\n'
cache_root="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew --cache)" || {
  printf 'Cache root: unknown; metadata failed\n' >&2
  exit 1
}
case "$cache_root" in
  /*) ;;
  *) printf 'Cache root: unknown; expected an absolute path\n' >&2; exit 1 ;;
esac
cache_root="${cache_root%/}"
case "$cache_root" in
  ''|/|"$HOME"|*/../*|*/..|*/./*|*/.|*//*|*$'\n'*|*$'\r'*)
    printf 'Cache root: unknown; invalid or profile-wide scope\n' >&2; exit 1 ;;
esac
probe="$cache_root"
while [ "$probe" != / ]; do
  if [ -L "$probe" ]; then
    printf 'Cache root: review-only; linked scope skipped\n' >&2
    exit 1
  fi
  probe="${probe%/*}"
  [ -n "$probe" ] || probe=/
done
printf 'Cache root: %s\n' "$cache_root"
if [ ! -e "$cache_root" ]; then
  printf 'Cache usage: unknown; root absent or inaccessible (not a cleanup target)\n' >&2
  exit 1
fi
if [ ! -d "$cache_root" ]; then
  printf 'Cache usage: unknown; not a directory\n' >&2
  exit 1
fi
if cache_usage="$(du -Psk "$cache_root")"; then
  cache_kib="${cache_usage%%[[:space:]]*}"
  case "$cache_kib" in
    ''|*[!0-9]*) printf 'Cache usage: unknown; malformed measurement\n' >&2; exit 1 ;;
  esac
  printf 'Cache usage (KiB, scope only): %s\n' "$cache_kib"
else
  printf 'Cache usage: unknown; incomplete measurement\n' >&2
  exit 1
fi
```

**Preview broader maintenance separately.** Only with an already verified,
working Homebrew/Ruby installation and fresh evidence that no install, update,
upgrade or build is active, capture this optional read-only preview in private
run scratch (15-second limit; no automatic retry). If runtime readiness, updater
state or preview coverage is unknown, report **preview unavailable/manual-required**.
Do not bootstrap Ruby, repair Homebrew, fetch metadata, update, upgrade or install
anything to make discovery work. The environment switches below disable
auto-update and analytics; they are not proof of runtime readiness or ownership.

```bash
# Homebrew maintenance preview (read-only; readiness checks required)
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew cleanup --dry-run --scrub
```

Classify preview findings as **download-cache**, **installed-version**,
**lock/prefix maintenance**, or **unknown**. Show only relevant path/scope metadata,
not raw diagnostics or configuration. Never convert preview lines into deletion
commands. A preview that omits a cached download does not prove the cache is empty;
retained installed downloads remain part of measured usage, not expected recovery.
Do not sum preview estimates with the cache directory size.

**No automatic Homebrew mutation.** Even a cache-only-looking preview does not
establish a cache-only executor. Keep maintenance manual-only rather than silently
running broader cleanup for a cache selection, a general confirmation or `all`.
Never remove the cache root/contents wholesale or redirect the current tool into a
legacy store. Preserve installed current/newest/pinned/live versions. Any future
automated action needs its own exact displayed scope and an appropriate supported
executor, with refreshed target identity, cache configuration, selectors,
consumer/liveness and install/update state; changed, active or uncertain scopes
must be skipped. The current workflow grants no such Homebrew execution authority.

Collect: exact resolved cache root, measured usage and method/completeness,
**unknown uniquely reclaimable bytes**, preview availability/scope classes,
and **manual-required** status. Apply the reporting threshold to usage, without
turning the informational row into a selectable deletion option.

**MacPorts:**
- Detection: `command -v port`
- Two paths to measure separately:
  - Downloaded source tarballs: `du -sm /opt/local/var/macports/distfiles 2>/dev/null | cut -f1`
  - Build directories left from interrupted compiles: `du -sm /opt/local/var/macports/build 2>/dev/null | cut -f1`
- Skip if total < 100 MB.
- Clean (Step 6): **Requires sudo.** `sudo port reclaim` walks the user through cleaning distfiles, build dirs, and optionally uninstalling unused dependent ports — it's interactive, run in the user's terminal so they can answer prompts.

Collect: tool name, path, size.

---

#### Category: Browser Caches (macOS only)

**Skip if platform is not macos.** Safari and Firefox on macOS store caches under `~/Library/Caches/` and are already covered by the App Caches scan; this category targets the Chromium family, which stores its cache under `~/Library/Application Support/<browser>/` instead. (Same blind-spot pattern as the Linux Chromium-family category.)

Probe each browser's root — include only if the directory exists. Each browser may have multiple profiles (`Default`, `Profile 1`, …) — sum across all of them and across the three cache subtypes (`Cache`, `Code Cache`, `GPUCache`).

| Browser | Cache root |
|---------|------------|
| Google Chrome | `~/Library/Application Support/Google/Chrome/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Chromium | `~/Library/Application Support/Chromium/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Brave | `~/Library/Application Support/BraveSoftware/Brave-Browser/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Microsoft Edge | `~/Library/Application Support/Microsoft Edge/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Vivaldi | `~/Library/Application Support/Vivaldi/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Arc | `~/Library/Application Support/Arc/User Data/<profile>/Cache`, `…/Code Cache`, `…/GPUCache` |
| Opera | `~/Library/Application Support/com.operasoftware.Opera/Cache` (single-profile, doesn't follow the `<profile>` subdir pattern) |

Discovery pattern (Bash, macOS):
```bash
APP_SUP="$HOME/Library/Application Support"
for browser_root in \
  "$APP_SUP/Google/Chrome" \
  "$APP_SUP/Chromium" \
  "$APP_SUP/BraveSoftware/Brave-Browser" \
  "$APP_SUP/Microsoft Edge" \
  "$APP_SUP/Vivaldi" \
  "$APP_SUP/Arc/User Data" \
  "$APP_SUP/com.operasoftware.Opera"; do
  [ -d "$browser_root" ] || continue
  find "$browser_root" -maxdepth 3 -type d \( -name Cache -o -name "Code Cache" -o -name GPUCache \) 2>/dev/null
done
```

Measure each discovered path with `du -sm`. Group by browser (sum across profiles + cache subtypes). Skip browsers with < 50 MB. Skip the category if total across all browsers < 100 MB.

**IMPORTANT:** The affected browser(s) must be closed before cleaning. Refresh
owner/process and live-path checks for each exact selected cache immediately
before execution; incomplete coverage stays review-only. Open or locked files
can still be unlinked on Unix, so `fcntl` locks are not a deletion veto and must
not be expected to cause safe skips. Do not kill holders or change permissions.
Report actual access failures and partial results rather than hiding them.

Clean command (Step 6): `find <each cache directory path> -mindepth 1 -delete` per discovered cache dir (preserve the directory itself — the browser recreates it on next launch).

Collect: browser names, total size per browser, paths.

---

### Step 4: Build and Display Report

Assemble the scan results into a report table.

Before rendering, classify every material hotspot from the whole-drive or
scoped outlier pass:

- **Covered:** already represented by a curated category. Do not duplicate it;
  verify that the category's measured size and scope explain the hotspot.
- **Confirmed reclaimable:** regenerable data with a known owner and a deletion
  scope protected by the same liveness, ownership, freshness, and path gates as
  the nearest curated category.
- **Close application first:** regenerable cache whose owning application is
  running or may hold locks.
- **Human review:** user content, an unfamiliar path, uncertain ownership, or
  anything whose consequence cannot be proved from current evidence.
- **System-managed/protected:** operating-system/update data, package caches
  needed for repair, recovery state, or another protected control surface.
- **Live dependency:** any path used by a running process, active worktree,
  registered local MCP server, current runtime, or in-flight task.

Unexpected outliers classified as confirmed reclaimable or close-application
first may appear in a separate **Expanded audit** table with letter IDs. State
the exact path, evidence, consequence, and estimated size. They require explicit
per-item selection (for example, `audit A,C`) and must not be included in `all`.
Human-review, protected, and live items are informational only and never enter a
deletion list. `$WinREAgent` is protected while an update or rollback is pending.
Never show `hiberfil.sys` as an opportunity, tradeoff, or optional candidate.

**Only include categories that found reclaimable items** (total size > 0). Skip empty categories entirely.

Sort rows by size descending. Number them sequentially (1, 2, 3...) based on what's shown — these are NOT fixed category IDs.

Display format:

```
Disk: [free]GB free / [total]GB total ([used]%)

 #  Category                  Items                              Size
 1  [largest category]        [brief item list]                  X.X GB
 2  [next category]           [brief item list]                  XXX MB
 3  [next category]           [brief item list]                  XXX MB
 ...
                                                         Total: X.X GB
```

For the "Items" column, show up to 3 specific names then `(+N more)` if there are additional items.

Homebrew cache usage and its maintenance preview are informational/manual-only;
show them separately, never in selectable category totals or `all`. Broader
installed-version maintenance is not authorized by a cache report or selection.

### Step 5: User Selection

**If `--dry-run` mode:** Stop here. Do not prompt for selection or perform any deletions.

Otherwise, ask the user:

> Which categories to clean? Enter numbers (e.g., `1,2,3`), `all`, or `none` to cancel.

Wait for user response. Parse their selection:
- Specific numbers: clean only those categories
- `all`: clean everything in the report
- `none`: cancel, do not delete anything

`all` covers only the numbered curated-category table. Expanded-audit letters
must be named explicitly after the user has seen their evidence and consequence.

### Step 6: Execute Cleanup

**First, snapshot free space NOW** — immediately before each selected operation —
using **Free-space measurement (platform dispatch)** in Step 1: the target-drive
Windows helper on Windows, `macos_report.py snapshot` on macOS, or
`df -Pk "<selected path or verified existing parent>"` on Linux.
This fresh pre-operation value, **not** the scan baseline, is the
"before" for the summary. Record the filesystem and retained measurement parent
so Step 7 can use the same scope after removal. Invalid measurements remain unknown.

For each selected category, execute the appropriate cleanup.

**Permission and safety-hook denials (all platforms):** Stop the blocked
operation. Never change syntax, wrappers or tools to evade a denial: translating
`rm` to `find -delete`, hiding deletion inside a script, or choosing another
launcher does not grant permission. Obtain policy resolution before continuing
that operation; do not retry it through another route while the denial remains.
The command table describes mechanisms, not permission to execute them.

**Approved Windows executors:** Use the committed structured executor for
migrated categories. For supported legacy categories, write exact selected paths
to a list, apply the refreshed `assert_list.py` gates below, and invoke the
committed `scrub.ps1` only when that executor and scope are permitted by the
active policy. A launcher without deletion keywords is not evidence of approval.
It reports `OK`/`PARTIAL`/`FAIL`/`SKIP` per path. User-owned paths do not inherently
need elevation; protected system targets still require the trusted elevated
worker described below. Never use a helper to bypass a blocked operation.

**Filter paths with `grep -F`, never bare `grep` — and never `grep -iF`.** Windows paths are backslash-laden and every regex-flavoured tool reads a backslash as an escape. `grep -v '\Claude\'` does not exclude Claude — it **errors** with `grep: Trailing backslash` and matches nothing, and when the output is redirected the exit status is lost, so it appends nothing and looks fine. Use `grep -vF` / `grep -cF` (fixed-string) for **all** path filtering.

**`grep -i -F` aborts on this platform.** GNU grep 3.0 as shipped in Git for Windows (`/usr/bin/grep`, and `fgrep`, which *is* `grep -F`) dies with **SIGABRT / exit 134** whenever `-i` and `-F` are combined — for *any* input, including `echo hello | grep -c -i -F hello`. It is the flag combination, not the pattern, the file, or CRLF. This matters more than a normal crash: an abort inside a list-building pipeline emits **nothing**, and nothing is exactly what the silent-omission bug looks like. Measured on the same file, same pattern:

| invocation | result |
|---|---|
| `grep -cF '\_npx'` | `3` — correct |
| `grep -ci '\_npx'` | `0` — silently wrong (backslash eaten as an escape) |
| `grep -c '\_npx'` | `0` — silently wrong |
| `grep -ciF '\_npx'` | **abort, exit 134, no output** |

So: **`-F` without `-i`.** Windows paths from the same source have stable casing, so case-sensitivity is rarely the problem it looks like. If you genuinely need case-insensitive fixed-string matching, do it in **Python** (`a.lower() in b.lower()`) or PowerShell (`-like`), never in grep — `assert_list.py` matches case-insensitively for exactly this reason.

The same trap has a Python cousin: `r'\Claude\'` is a SyntaxError (a raw string cannot end in a backslash) — use `chr(92)` to build the separator, and pass paths as **argv** so MSYS converts them (a `/tmp/...` literal inside a script is not converted).

**Assert the list with `assert_list.py` before every `scrub.ps1` call. Never delete off an unverified list.**

```bash
powershell.exe -NoProfile -File "$(cygpath -w "$CLEANUP_SCRIPTS/live_paths.ps1")" > /tmp/agentic-cleanup/live.txt
python "$CLEANUP_SCRIPTS/assert_list.py" "$(cygpath -w <listfile>)" \
  --require 'electron cache=\AppData\Roaming\' \
  --require 'user temp=\AppData\Local\Temp\' \
  --forbid  'Claude cache=\Claude\' \
  --forbid  'CC scratch=\Temp\claude\' \
  --live    "$(cygpath -w /tmp/agentic-cleanup/live.txt)"   || exit 1
```

One `--require` per category the user selected, one `--forbid` per thing you excluded by hand. It fails on a require bucket matching **0** lines, on any forbid hit, on an empty list, and on any line matching no bucket. **A selected category showing `0` is a bug, not a clean bill of health** — that is the whole point.

**`--live` is the liveness veto.** `live_paths.ps1` reads the process list and emits every path a running process depends on; `assert_list.py` fails any target that is an *ancestor* of one. This is the only non-proxy signal available: git inactivity, registry absence and "no lockfile" all mean "probably dead", and on 2026-07-16 they were wrong five times in one run — four caught by a **file lock rather than by judgement**. Verified against that run's sharpest case: a whole-dir `npm-cache` target is vetoed because 3 live MCP servers execute from `_npx` beneath it (once per session), which is precisely what `Access denied` accidentally prevented.

It does **not** subsume `find_targets.py`'s `backs_mcp_server()`. A book-power MCP runs from `<project>\dist\index.js`, so nothing live sits under its sibling `node_modules` — the veto sees nothing there, while `backs_mcp_server()` protects it by knowing the project owns a registered server. Keep both.

*Why a committed script and not an inline check* (2026-07-16): the run **did** verify, and the verification was broken **the same way as the bug**. `grep -v '\Claude\'` silently appended nothing, so the entire Electron category — 42 dirs, ~1.4 GB, the largest selection — vanished from the delete list while `wc -l` reported a healthy 197 lines. The check `grep -c 'AppData\Roaming' "$LIST"` then died on the identical trailing backslash and printed `0` next to a "must be 0" row for a *different* category, so the wrong answer read as a passing test. A check that fails identically to the thing it checks is worse than no check. `assert_list.py` matches fixed-string off argv, in code, and is regression-tested against that exact 197-line list.

**NEVER pass `npm-cache` or `_npx` itself to `scrub.ps1`.** `%LOCALAPPDATA%\npm-cache\_npx\` is where `npx -y <pkg>` materialises packages, and **live MCP servers execute from inside it** — on a machine running Claude Code you will typically find `node …\npm-cache\_npx\…\harmonica-mcp\dist\index.js` (and context7, shadcn, etc.) in the process list, once per running session. A whole-directory `rmdir /s /q` deletes those servers' code out from under every running session. Use **`npm cache clean --force`** for `_cacache`. The only supported `_npx` removal is an individually listed immediate child that passed the 7-day age test and a refreshed live-path veto. Validate that every target's canonical parent is exactly `_npx`, then run `assert_list.py --require '\_npx\' --live <fresh-live-paths>` before `scrub.ps1`. Observed 2026-07-16: scrub on the cache root returned `Access is denied` **because** two sessions held it; the lock was the only thing preventing the damage. Do not "fix" that failure by retrying harder or killing the holder. Never replace a denied operation with an ad-hoc script. Preserve the committed executor's policy and path gates; its worker must not be named `Del`/`RD`/`RM` (see the alias trap below).

**Alias trap (Windows/PowerShell):** `del`, `rd`, and `rm` are aliases for `Remove-Item`, and aliases outrank functions in command resolution. Never name a delete-helper function `Del` / `RD` / `RM` — the alias shadows it, the function body (delete + logging) silently never runs, and it looks like it "succeeded" (sub-second, no freed space, missing log lines). Use a non-aliased name such as `Scrub`. Inside the `.ps1`, `cmd /c rmdir /s /q "<path>"` is fastest for whole-dir removal (e.g. a superseded Squirrel `app-*` version, an individually validated stale `_npx` child, or an inactive project's `node_modules`); use `Remove-Item "<dir>\*" -Recurse -Force` for contents-only where the dir must survive (e.g. `C:\Windows\Temp`). **Do not reach for the fast whole-dir form on `npm-cache` or `_npx` itself** — see the warning above.

**Elevated cleanup (Windows):** use the committed executor or maintenance worker
from an already elevated trusted process. Otherwise return `manual-required`.
Do not generate user-writable elevated scripts or silently trigger UAC. `-Verb
RunAs` cannot be combined with stdout redirection. The worker writes its own
structured result; launch/UAC outcome, worker exit and operation status are
distinct evidence. An empty/missing result does not prove elevation was declined.

**Categories requiring elevation:** LiveKernelReports, CBS logs, OEM logs, VS Package Cache, Delivery Optimization, Windows SDK old versions, Orphaned VS installations, WinSxS component cleanup, Config.Msi leftovers, Windows.old (manual only).

**Full cleanup command reference:**

| Category | Clean Command |
|----------|--------------|
| Squirrel old versions | `rm -rf <each old app-* directory path>` |
| node_modules (inactive) | `rm -rf <each inactive project>/node_modules` |
| npm cache | `npm cache clean --force` for `_cacache`; `scrub.ps1`/`find -delete` only for exact stale `_npx` children after age, canonical-parent, and refreshed liveness validation |
| pnpm cache | `pnpm store prune` for the active store; separately approved exact legacy-generation contents only after refreshed ownership/liveness/sharing checks; never substitute the active store or project dependencies |
| yarn v1 cache | `yarn cache clean` |
| yarn v2+ cache | `yarn cache clean --all` |
| pip cache | `pip cache purge` (or `pip3 cache purge`) |
| Claude Code debris | Clear selected `debug`/`telemetry`, exact stale `mcp-logs-*` directories, and qualified superseded version entries; preserve all conversation/session logs, file-edit history, memories/settings, and the running/newest Claude versions |
| Downloaded model caches | Clear only `~/.cache/huggingface` after model-process and live-path vetoes; dependent models re-download |
| Browser automation downloads | Clear only selected `ms-playwright` or `~/.cache/puppeteer` contents after the live-path veto; browsers re-download |
| Crash dumps | `rm -rf <CrashDumps path>/*`. LiveKernelReports: **elevated** `Remove-Item "C:\Windows\LiveKernelReports\*" -Recurse -Force` |
| Build artifacts | Windows: committed scan/plan/executor, refreshing 24-hour freshness, liveness and links. For exact `.next/cache` contents use `scan.ps1 -BuildCacheOnly`; preserve root and siblings. Unix: recheck the same gates before the exact selected removal. |
| Docker (images) | `docker image prune -f` |
| Docker (build cache) | `docker builder prune -f` |
| App caches | Exact selected cache contents only, preserving the root, after confirming the owner is closed and refreshing owner/process and live-path evidence; unknown or incomplete ownership stays review-only. Open/locked files are not a safety veto |
| Windows.old | **Cannot be deleted via CLI.** Instruct the user to use Settings > System > Storage > Temporary files > Previous Windows installation(s), or Disk Cleanup as Administrator. |
| Delivery Optimization | Use supported Settings > Storage > Temporary files; no implicit service stops. |
| Windows Temp files | **Elevated for system temp.** User temp: PowerShell `Get-ChildItem "$env:TEMP" | Where-Object { $_.Name -notin @('agentic-cleanup','claude-cleanup','claude','opencode') } | Remove-Item -Recurse -Force` — all four exclusions are required; `claude` and `opencode` are live runtime scratch directories, and deleting either can kill the running command. System temp: **elevated** `Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force` |
| Browser caches | `rm -rf <each cache directory path>/*` (contents only). Warn user to close browsers first. |
| Electron app caches | `rm -rf <each cache directory path>/*` (contents only), including exact Zoom `data\WebviewCacheX64` contents. Warn user to close affected apps first. |
| Stale updater files | `rm -rf <each updater directory path>/*` for directories, `rm -f <path>` for individual .nupkg files. |
| AppData remnants | `rm -rf <each confirmed orphan path>` — **requires per-item user confirmation** before deleting. |
| Windows SDK old versions | Separately approved supported Microsoft uninstall after dependency review; never manual SDK directory deletion. |
| Orphaned VS installations | **Elevated:** `Remove-Item "<path>" -Recurse -Force` for each orphaned VS directory. |
| Windows System Logs | **Elevated:** committed `maintenance.ps1` scan → exact selected evidence → CleanLogs; preserve current/newest/fresh/changed/linked/locked logs and roots. |
| VS Package Cache | **Elevated:** `Remove-Item "$env:ProgramData\Microsoft\VisualStudio\Packages\*" -Recurse -Force` |
| WinSxS component store | **Elevated:** committed `maintenance.ps1` Analyze → Components with fresh servicing guards, bounded waits and `/NoRestart`. No `/ResetBase`, reboot or repeated pass. Bytes unknown until measured. |
| Config.Msi leftovers | **Elevated:** `Remove-Item "C:\Config.Msi" -Recurse -Force` (only when no install is in progress). |
| System pkg manager cache (Linux) | **Requires sudo.** dnf: `sudo dnf clean all` · apt: `sudo apt clean` · pacman: `sudo pacman -Sc --noconfirm` · zypper: `sudo zypper clean --all` |
| journald logs (Linux) | **Requires sudo.** `sudo journalctl --vacuum-time=30d` (or `--vacuum-size=200M` for hard cap) |
| Flatpak unused runtimes (Linux) | `flatpak uninstall --unused -y` (system installs prompt for sudo) |
| Old kernels (Linux) | **Requires sudo.** Fedora/RHEL: `sudo dnf remove $(dnf repoquery --installonly --latest-limit=-1 -q)` · Debian/Ubuntu: `sudo apt autoremove --purge`. Always keep current + previous kernel. |
| Trash (Linux/macOS) | `find <trash_path> -mindepth 1 -delete` for each location. Linux primary: `~/.local/share/Trash` (recreate `files/` + `info/` subdirs after). macOS primary: `~/.Trash`. Confirm before clearing. |
| Dev tool caches (Linux/macOS) | Per-tool: cargo `cargo cache --autoclean` (or `find -delete` on `~/.cargo/registry` and `~/.cargo/git/db`) · Go **`go clean -modcache`** (NOT `find -delete` — module cache is read-only) · uv `uv cache clean` · Poetry `poetry cache clear --all -n .` · ccache `ccache -C` · others `find <path> -mindepth 1 -delete` |
| Orphaned config/data dirs (Linux) | `find <orphan_path> -mindepth 1 -delete && rmdir <orphan_path>` per orphan — **requires per-item user confirmation** (false positives common from portable / curl-installed apps). |
| Browser caches (Linux) | Exact selected cache contents only, preserving roots, after confirming browsers are closed and refreshing owner/process and live-path checks. Open/locked files are not a safety veto; incomplete evidence stays review-only. Firefox cache candidates are discovered by App Caches via `~/.cache/mozilla`. |
| System pkg manager cache (macOS) | Homebrew: informational/manual-only, excluded from selectable categories and `all`; only the separately described `brew cleanup --dry-run --scrub` preview is permitted after readiness checks, never broad cleanup or wholesale cache deletion for a cache selection. MacPorts: **requires sudo**, run `sudo port reclaim` in the user's terminal (interactive). |
| Browser caches (macOS) | Exact selected cache contents only under `~/Library/Application Support/`, preserving roots, after confirming browsers are closed and refreshing owner/process and live-path checks. Open/locked files are not a deletion veto; incomplete evidence stays review-only. Safari/Firefox cache candidates are discovered by App Caches. |

**Show progress** as each category is cleaned: what's being deleted and confirmation when done.

**Partial failure handling:** If cleaning a category fails (e.g., permission denied, Docker daemon stopped mid-operation), log the error and continue with remaining selected categories. Track failures for the summary.

### Step 7: Clean up scratch + Summary

**Remove only this run's scratch.** After its exact workers finish, preserve any
requested durable evidence, remove the uniquely task-owned directory, and verify
physical absence. Never delete the shared cleanup root or another session's data.

**Re-measure** free space using **Free-space measurement (platform dispatch)**
in Step 1: the target-drive helper on Windows, `macos_report.py snapshot` on macOS,
or `df -Pk "<verified existing parent>"` on Linux.
Use each operation's recorded filesystem and retained parent,
after this run's scratch removal. Do not substitute `/`, a different drive or a
rounded human-readable value for the recorded scope. If either paired measurement
is invalid, report net change as unknown, not zero.

**Compute `freed = after_free − before_free`, where `before_free` is the PRE-DELETION snapshot from Step 6** — not the Step 1 scan baseline. Using the Step 1 value understates the result because the run itself consumed ~200 MB (the CSV) between scan and deletion.

```
Completed selected operations. Net free-space change: +/- X.X GiB.
Logical selected-scope decrease: X bytes; uniquely reclaimed bytes: unknown.
```

**Accounting caveats — state these when they apply, so a small measured number isn't mistaken for failure:**
- **Hardlink overlap.** WizTree per-category sizes for `node_modules` and the pnpm/Bun store are *logical* — those trees share content-addressed blocks via hardlinks, so deleting them frees only the unique data. Selected-total can far exceed measured reclaim (2026-06-26: ~1.4 GB selected → ~0.5 GB freed). Real reclaim lands only when the **last** reference is removed, so pair store pruning with inactive `node_modules` in the same run. Label these sizes "logical, may overlap" in the Step 4 report.
- **Concurrent writes.** Another active session building/downloading during the run moves free space independently; the net number reflects both, and can even go slightly negative under heavy concurrent writes despite a clean delete.

If any categories failed during cleanup, list them:

```
Failed: [category name] ([error reason])
```
