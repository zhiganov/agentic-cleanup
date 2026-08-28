# agentic-cleanup

Safe disk cleanup for coding agents. One `/cleanup` command scans a developer workstation for reclaimable disk space, reports what it finds, and deletes only the categories the user selects.

## Install

macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.ps1 | iex
```

Both installers add the same runtime-neutral `cleanup.md` to:

- Claude Code: `~/.claude/commands/cleanup.md`
- OpenCode V2: `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cleanup.md`

Helpers, contracts, and the release manifest live once under `${XDG_DATA_HOME:-~/.local/share}/agentic-cleanup`. The installers stage and SHA-256 verify a complete release before publishing the manifest, and the command refuses to run if any selected runtime copy differs from that verified payload.

Install for only one runtime by setting `AGENTIC_CLEANUP_RUNTIME` to `claude` or `opencode` (`all` is the default):

```powershell
$env:AGENTIC_CLEANUP_RUNTIME = 'opencode'
irm https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master/install.ps1 | iex
Remove-Item Env:AGENTIC_CLEANUP_RUNTIME
```

## Usage

```
/cleanup              # scan, report, select, clean
/cleanup --dry-run    # scan and report only
/cleanup --structured-preview  # immutable five-category Windows evidence preview
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

## Windows helper scripts

On Windows the scan and delete steps are backed by committed helper scripts in [`scripts/windows/cleanup/`](./scripts/windows/cleanup/) — a size lookup over the WizTree CSV, the `node_modules` / build-artifact finder, the elevated WizTree export, the orphan/old-version discovery scripts, and allowlisted structured executors. Versioned scan/plan/result contracts live in [`scripts/cleanup/`](./scripts/cleanup/). The installers place both under the shared agent-neutral data directory; the command resolves them automatically. macOS/Linux runs need no helper scripts.

## What It Scans (31 categories)

The skill detects the OS at runtime and only scans categories that apply.

### Platform coverage

| Platform | Status | Notes |
|----------|--------|-------|
| Windows (MSYS2/Git Bash) | **Validated** | All Windows-only categories including elevated cleanup, WizTree fast-scan, AppData remnants, VS / SDK orphans. |
| Linux — Fedora (dnf/rpm) | **Validated** | Tested with the orphan scan's 4-layer filter chain (allowlist + active-binary + 30-day mtime + token-boundary package match). |
| Linux — Debian/Ubuntu (apt) | Written, **not exercised** | Detection and clean commands present but not run against a real Debian system yet. |
| Linux — Arch (pacman), openSUSE (zypper) | Written, **not exercised** | Same as Debian. |
| macOS | Written, **not exercised** end-to-end | All categories present: App Caches, Trash, Dev Tool Caches, Homebrew/MacPorts cache, Chromium-family browser caches under `~/Library/Application Support/`. Symmetric to Linux but hasn't been run on a real Mac. |

### Cross-platform (7)

| Category | What it finds |
|----------|---------------|
| node_modules (inactive) | `node_modules` in projects with no git activity in 4+ weeks (resolves repo root before testing — handles monorepos with nested packages) |
| Package manager caches | npm, pnpm, yarn global caches |
| pip cache | Python package cache |
| Claude Code debris | Debug logs, telemetry, old session logs (4+ weeks) |
| Crash dumps & kernel reports | CrashDumps + LiveKernelReports (multi-GB watchdog dumps on Windows); equivalent on Linux/macOS |
| Build artifacts | `.next/`, `.turbo/`, `.parcel-cache/`, `.vite/` in inactive projects |
| Docker | Dangling images, build cache |

### Windows-only (13)

| Category | What it finds |
|----------|---------------|
| Squirrel old versions | Old Electron app versions (Slack, Discord, Figma, etc.) |
| Windows.old | Previous Windows installation (10-30 GB after upgrades) |
| Delivery Optimization | Windows Update distribution cache (up to 20 GB) |
| Windows Temp files | `%TEMP%` and `C:\Windows\Temp` |
| Browser caches (Windows) | Chrome, Edge, Firefox, Brave cache and code cache |
| Electron app caches | Cache dirs in Slack, Discord, Miro, Claude Desktop, Notion, etc. |
| Stale updater files | Applied update packages in Linear, Notion, Signal, Squirrel apps |
| Playwright browsers (Windows) | Downloaded browser binaries in `ms-playwright` |
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
| System pkg manager cache | Homebrew (`brew cleanup -s`), MacPorts (`sudo port reclaim`, interactive) |
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
 7  Playwright browsers       chromium-1208, chromium_headless    655 MB
 8  Windows Temp files        User temp (282 MB)                  282 MB
 9  node_modules (inactive)   dear-neighbors, my-community        141 MB
                                                         Total: 11.3 GB

Which categories to clean? Enter numbers (e.g., 1,2,3), all, or none to cancel.
```

## Safety

- **Report first, act second.** Nothing is deleted until you choose.
- **WizTree = fast + safe.** Only used for size measurements, never deletes anything.
- **Keeps newest versions.** Squirrel cleanup only removes old `app-*` directories.
- **Respects active projects.** Only cleans node_modules and build artifacts in projects with no git activity in 4+ weeks.
- **Protects Claude Code data.** Never touches memories, commands, skills, settings, or history.
- **Safe Docker cleanup.** Only prunes dangling images and build cache — never removes stopped containers or volumes.
- **Single UAC prompt.** Elevated categories (system logs, VS cache, kernel reports) are batched into one admin PowerShell invocation.
- **Browser/app-safe.** Warns to close apps before cleaning caches; locked files are skipped automatically.
- **Skips missing tools.** If Docker, pip, pnpm, yarn, or WizTree isn't installed, gracefully falls back or skips.
- **Handles failures gracefully.** If one category fails, continues with the rest and reports what failed.

## License

MIT
