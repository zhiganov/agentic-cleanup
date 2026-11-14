# agentic-cleanup

Safe disk cleanup for coding agents. One `/cleanup` command scans a developer workstation for reclaimable disk space, reports what it finds, and deletes only the categories the user selects.

This repository is the sole source for the command, skill, helpers, contracts,
tests and installers. Installed runtime copies are release consumers; there is
no companion implementation or synchronization dependency in a config repository.

## Install

macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.ps1 | iex
```

Both installers add the same thin `/cleanup` command to:

- Claude Code: `~/.claude/commands/cleanup.md`
- OpenCode V2: `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cleanup.md`

The command delegates to an `agentic-cleanup` skill installed under each selected runtime's `skills/agentic-cleanup/SKILL.md`. The full workflow, helpers, contracts, and release manifest also live under `${XDG_DATA_HOME:-~/.local/share}/agentic-cleanup`. The installers stage and SHA-256 verify the complete release before publishing the manifest, and the skill verifies the active runtime's command/skill pair against that payload without inspecting another runtime.

Install for only one runtime by setting `AGENTIC_CLEANUP_RUNTIME` to `claude` or `opencode` (`all` is the default):

```bash
curl -fsSL https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.sh | AGENTIC_CLEANUP_RUNTIME=opencode bash
```

```powershell
$env:AGENTIC_CLEANUP_RUNTIME = 'opencode'
irm https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.ps1 | iex
Remove-Item Env:AGENTIC_CLEANUP_RUNTIME
```

A single-runtime install or upgrade reads and writes only that runtime's command/skill pair. Use `all` only when you explicitly want both runtimes updated.

## Usage

```
/cleanup              # scan, report, select, clean
/cleanup --dry-run    # scan and report only
/cleanup --structured-preview  # immutable six-category Windows evidence preview
```

The structured preview is the first migration slice of the testable contract
pipeline and requires PowerShell 7 (`pwsh`). Ordinary cleanup remains available
without it while the remaining categories are migrated.

## Portable variant (no install)

A slimmer, harness-agnostic version lives as a [public gist](https://gist.github.com/zhiganov/c8b611bd27e90979068051bd371f0d95) — paste it into any LLM with shell access (Claude Code, Cursor, Codex, ChatGPT with code interpreter). Unix-first, Windows in an appendix, no embedded PowerShell. Source: [`cleanup-gist.md`](./cleanup-gist.md) in this repo.

## WizTree Acceleration (Windows)

If [WizTree](https://www.diskanalyzer.com/) is installed, the scan phase completes in seconds instead of minutes. WizTree reads the NTFS Master File Table directly for instant directory sizes.

- Auto-detected from common install paths
- Falls back to PowerShell scanning if not installed
- Also accepts a manually-exported WizTree CSV
- Uses the whole-drive export to find material outliers beyond the fixed category list

The outlier pass is read-only evidence. Each unexpected hotspot is classified as
reclaimable, close-application-first, human-review, system-managed/protected, or
live before it can be offered. Unknown paths are never automatic deletion
targets, and expanded-audit candidates require explicit per-item selection.

Folder-hotspot discovery retains large files at drive roots and shallow directory
levels. A protected system file appearing in this read-only evidence is not a
cleanup target.

The initial ordinary scan also inventories superseded tool releases and all
generations under discovered cache-store roots, rather than stopping at the
active version/store. Current, newest, pinned and live installations stay
protected. Qualified older Codex releases and legacy pnpm generations appear as
exact, separately selectable expanded-audit items; they are never part of `all`.

Largest files can be reported independently with `find_outliers.py --files
--json`: folder grouping and depth limits no longer hide nested individual files.
Without a fresh index, `file_audit.py` audits only explicitly selected known
folders or exact roots, resolving Windows redirection and reporting overlaps,
links, inaccessible paths, budget limits and top-N omissions. It never opens file
contents, hydrates cloud placeholders, relocates files or deletes personal data.
Traversal holds no-follow directory scopes, including ancestors, so replacing a
directory cannot redirect metadata reads. Busy/unpinnable paths are disclosed as
incomplete coverage rather than followed through a weaker fallback.

The skill now has a short governing entry point and on-demand category recipes.
Reports distinguish logical size, local allocation, unknown uniquely reclaimable
storage and observed signed net disk change. The default selectable threshold is
50 MiB and can be changed without weakening deletion boundaries.

Windows cache-only plans preserve `.next/cache` roots and sibling build output.
Exact absent selections are validated no-ops. Old Windows logs use a committed
exact-file worker instead of wildcard deletion, protecting current/newest,
changed, fresh, linked and locked files. Supported DISM runs use `/NoRestart`,
conservative servicing guards and bounded natural-exit waits, never `/ResetBase`
or an automatic second pass. Elevated mutation requires an already elevated
trusted process; missing worker output is not interpreted as declined UAC.

## Windows helper scripts

On Windows the scan and delete steps are backed by committed helper scripts in [`scripts/windows/cleanup/`](./scripts/windows/cleanup/) — a size lookup over the WizTree CSV, whole-drive outlier discovery, the `node_modules` / build-artifact finder, the elevated WizTree export, the orphan/old-version discovery scripts, and allowlisted structured executors. Versioned scan/plan/result contracts live in [`scripts/cleanup/`](./scripts/cleanup/). The installers place both under the shared agent-neutral data directory; the skill resolves them automatically.

## macOS discovery adapter

Ordinary `/cleanup` and `/cleanup --dry-run` use committed `macos_scan.py` and
`macos_ownership.py`, requiring an **existing Python 3.10+**. No dependency is
installed implicitly. They reuse the file-audit helper's no-follow POSIX scopes,
file identities and allocation methods, with explicit time/depth/entry bounds.

The read-only inventory identifies bounded app/cache owners, exact sandbox/browser
cache subtrees, configured tool caches, runtime release families and pnpm store
generations. Static local MCP registrations protect idle project dependencies;
process/open-path evidence protects observed live consumers. Incomplete or dynamic
ownership stays review-only. It never persists commands, credentials or config bodies.

Evidence is a new private JSON file, with coverage/skips/budgets/top-N disclosed.
It is **not an executable cleanup plan**: all items remain non-selectable until
independent category eligibility, selection and refreshed checks. No whole-drive
claim, group-container/VM deletion, app stopping, runtime change or APFS reclaim
estimate is introduced. Homebrew remains manual-only. Use supported in-app clearing
where appropriate; user-reported manual clearing is not measured recovery.

The committed `macos_report.py` renders saved evidence with explicit coverage
gaps and per-filesystem space observations. Actual target devices, APFS shared
containers/System-Data groups and external volumes are kept distinct; capacity
and free space are never summed across shared volumes. Logical/allocation
subtotals are not unique recovery estimates, including for clones/snapshots.
Read-only snapshots support fresh per-operation and post-scratch comparisons;
signed net changes can be negative and do not prove what caused them.

Measurements share the remaining global entry/time budget across discovered
non-overlapping targets, so a large early store cannot consume every later
target's share. Per-root cuts and unmeasured scopes remain explicit and unknown.
The scanner does not silently raise limits or repeat a cut-short walk.

## What It Scans (32 categories)

The skill detects the OS at runtime and only scans categories that apply.

### Platform coverage

| Platform | Status | Notes |
|----------|--------|-------|
| Windows (MSYS2/Git Bash) | **Validated** | All Windows-only categories including elevated cleanup, WizTree fast-scan, AppData remnants, VS / SDK orphans. |
| Linux — Fedora (dnf/rpm) | **Validated** | Tested with the orphan scan's 4-layer filter chain (allowlist + active-binary + 30-day mtime + token-boundary package match). |
| Linux — Debian/Ubuntu (apt) | Scan exercised, **clean not exercised** | Dry-run scan run on Ubuntu 26.04 under WSL2 (2026-10-26): categories detected and measured as expected. No clean commands run yet. Under WSL2, `df /` reports the virtual disk's ceiling (default 1 TB), not the host drive's free space. |
| Linux — Arch (pacman), openSUSE (zypper) | Written, **not exercised** | Same as Debian. |
| macOS | Read-only scanner and isolated installation exercised; **automated cleanup not validated** | Native macOS disposable fixtures exercise the committed adapter and installed entry point. An earlier workstation dry run/manual app clearing does not validate automated deletion. |

### Cross-platform (9)

| Category | What it finds |
|----------|---------------|
| node_modules (inactive) | `node_modules` in projects with no git activity in 4+ weeks (resolves repo root before testing — handles monorepos with nested packages) |
| Package manager caches | npm `_cacache`, individually validated stale/non-live `_npx` entries, pnpm, and yarn caches |
| pip cache | Python package cache |
| Claude Code debris | Debug logs, telemetry, old session logs, stale MCP diagnostics, and superseded Claude binaries while preserving current/newest versions |
| Downloaded model caches | Hugging Face model downloads, protected while referenced by a running model process |
| Browser automation downloads | Playwright and Puppeteer browser distributions, protected while a test/browser process uses them |
| Crash dumps & kernel reports | CrashDumps + LiveKernelReports (multi-GB watchdog dumps on Windows); equivalent on Linux/macOS |
| Build artifacts | `.next/`, `.turbo/`, `.parcel-cache/`, `.vite/` in inactive projects |
| Docker | Dangling images, build cache |

### Windows-only (12)

| Category | What it finds |
|----------|---------------|
| Squirrel old versions | Old Electron app versions (Slack, Discord, Figma, etc.) |
| Windows.old | Previous Windows installation (10-30 GB after upgrades) |
| Delivery Optimization | Windows Update distribution cache (up to 20 GB) |
| Windows Temp files | `%TEMP%` and `C:\Windows\Temp` |
| Browser caches (Windows) | Chrome, Edge, Firefox, Brave cache and code cache |
| Electron app caches | Cache dirs in Slack, Discord, Miro, Claude Desktop, Notion, and Zoom's exact `data\WebviewCacheX64` subtree |
| Stale updater files | Applied update packages in Linear, Notion, Signal, Squirrel apps |
| Windows System Logs | CBS logs, OEM PC Manager logs |
| VS Package Cache | Visual Studio installer package cache |
| AppData remnants | Orphaned app data dirs for uninstalled programs (>50 MB, user-confirmed) |
| Windows SDK old versions | Old SDK versions in `Windows Kits\10\` (keeps newest) |
| Orphaned VS installations | VS directories the installer no longer tracks |

### Unix — Linux + macOS (11)

Shared (applies to both Linux and macOS):

| Category | What it finds |
|----------|---------------|
| App caches | Large cache directories under `~/.cache/` (Linux) or `~/Library/Caches/` (macOS); flags `claude-cli-nodejs` for user review since it's the running session's own cache |
| Trash | `~/.local/share/Trash` (Linux), `~/.Trash` (macOS), and per-volume `.Trashes/<uid>` on mounted drives |
| Dev tool caches | Cargo, Go modules (uses `go clean -modcache` for read-only handling), uv, Poetry, pip-tools, ccache, sccache, Gradle, Maven, Bun. Documents the hardlink/CAS caveat — `du` reports apparent size but `df` only reclaims when the last hardlink is gone (pair with `node_modules (inactive)` for real reclaim) |

Linux-only:

| Category | What it finds |
|----------|---------------|
| System pkg manager cache | dnf, apt, pacman, zypper caches (requires sudo to clean) |
| journald logs | Vacuums via `journalctl --vacuum-time=30d` (requires sudo) |
| Flatpak unused runtimes | Detects via `flatpak uninstall --unused --dry-run` |
| Old kernels | Keeps current + previous; warns before removing on Fedora/dnf and Debian/apt |
| Orphaned config/data dirs | `~/.config/*` and `~/.local/share/*` for uninstalled apps; 4-layer filter (allowlist + `command -v` active-binary + 30-day mtime + token-boundary package match) eliminates false-positives like `pnpm`/`claude` while still catching real orphans |
| Browser caches (Linux Chromium-family) | Chrome, Chromium, Brave, Edge, Vivaldi, Opera under `~/.config/<browser>/` (multi-profile, three cache subtypes each) |

macOS-only:

| Category | What it finds |
|----------|---------------|
| System pkg manager cache | Homebrew: actual configured cache usage plus an optional read-only maintenance preview; manual-only, outside `all` (cleanup can remove installed versions). MacPorts: `sudo port reclaim`, interactive. |
| Browser caches (macOS Chromium-family) | Chrome, Chromium, Brave, Edge, Vivaldi, Arc, Opera under `~/Library/Application Support/<browser>/` (Safari and Firefox are caught by App Caches) |

## Example Output

```
Disk: 6.5GB free / 120GB total (95%)

 #  Category                  Items                              Size
 1  VS Package Cache          VisualStudio\Packages              2.4 GB
 2  Crash dumps               LiveKernelReports (1 dump)         2.0 GB
 3  npm cache                 npm-cache                          1.9 GB
 4  Browser caches            Firefox, Chrome, Edge              1.7 GB
 5  Windows System Logs       CBS, PCManager                     1.3 GB
 6  Electron app caches       Miro, Claude Desktop, Slack        1.0 GB
 7  Browser automation        Playwright, Puppeteer               655 MB
 8  Windows Temp files        User temp (282 MB)                  282 MB
 9  node_modules (inactive)   dear-neighbors, my-community        141 MB
                                                         Total: 11.3 GB

Which categories to clean? Enter numbers (e.g., 1,2,3), all, or none to cancel.
```

## Safety

- **Report first, act second.** Nothing is deleted until you choose.
- **Evidence-first discovery.** Whole-drive or scoped top-consumer evidence finds unexpected outliers beyond the fixed categories; unknown paths remain review-only.
- **Hibernation stays enabled.** `hiberfil.sys` is suppressed from outlier results and is never suggested as a cleanup candidate.
- **WizTree = fast + safe.** Only used for size measurements, never deletes anything.
- **Keeps newest versions.** Squirrel cleanup only removes old `app-*` directories.
- **Respects active projects.** Only cleans node_modules and build artifacts in projects with no git activity in 4+ weeks.
- **Protects registered MCP projects.** The structured path excludes `node_modules` owned by static Claude Code or OpenCode V2 local-server registrations and refreshes ownership before execution.
- **Protects Claude Code data.** Never touches memories, commands, skills, settings, conversation/session logs, or file-edit history, regardless of age.
- **Safe Docker cleanup.** Only prunes dangling images and build cache — never removes stopped containers or volumes.
- **Single UAC prompt.** Elevated categories (system logs, VS cache, kernel reports) are batched into one admin PowerShell invocation.
- **Browser/app-safe.** Requires owners to be closed and refreshes owner/process and live-path checks before selected cache cleanup. Open/locked files are not a reliable deletion veto on Unix; uncertain owners stay review-only, cache roots are preserved, and partial/access failures are reported.
- **Respects permission denials.** Stop the blocked operation. Never change syntax, wrappers or tools to evade a safety hook or unresolved permission denial.
- **Homebrew scope stays explicit.** Cache usage is not an expected cleanup recovery amount. Homebrew maintenance is manual-only and excluded from selectable categories and `all`; cache selection never triggers installed-version cleanup or wholesale cache deletion.
- **Skips missing tools.** If Docker, pip, pnpm, yarn, or WizTree isn't installed, gracefully falls back or skips.
- **Handles failures gracefully.** If one category fails, continues with the rest and reports what failed.

## License

MIT
