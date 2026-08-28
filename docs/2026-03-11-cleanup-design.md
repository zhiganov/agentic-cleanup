# /cleanup — Developer Workstation Disk Cleanup

Slash command that scans a developer workstation for reclaimable disk space, reports findings in a categorized table, lets the user select which categories to clean, and executes the cleanup.

Published as `zhiganov/agentic-cleanup`, with installers for Claude Code and OpenCode V2.

## Invocation

```
/cleanup
/cleanup --dry-run   # report only, no selection/deletion step
```

Run from any directory. No other arguments.

## Scan Categories

The command scans these zones in parallel, then reports a unified table sorted by size descending.

| # | Category | What it finds | Win | Mac | Linux |
|---|----------|--------------|-----|-----|-------|
| 1 | Squirrel old versions | Old `app-*` dirs in Electron apps (keeps latest only) | Y | - | - |
| 2 | node_modules (inactive) | `node_modules` in projects with no git activity in 4+ weeks | Y | Y | Y |
| 3 | npm/pnpm/yarn cache | Package manager global caches | Y | Y | Y |
| 4 | pip cache | Python package cache | Y | Y | Y |
| 5 | Claude Code debris | `debug/`, `file-history/`, `telemetry/`, session logs older than 4 weeks | Y | Y | Y |
| 6 | Crash dumps | OS crash reports | Y | Y | Y |
| 7 | Build artifacts | `.next/`, `.turbo/`, `.parcel-cache/`, `.vite/` in inactive projects (gitignored `dist/` only) | Y | Y | Y |
| 8 | Docker | Dangling images, build cache (NOT stopped containers) | Y | Y | Y |
| 9 | App caches | Large app cache directories (>50 MB) | - | Y | Y |

### Category Details

**Squirrel old versions (Windows only):**
- Scan `~/AppData/Local/*/` for directories containing `Update.exe`
- Within each, find `app-*` subdirectories
- If more than one version exists, all except the newest are reclaimable
- Common offenders: Slack, Discord, Figma, Notion, Claude Desktop, TogglTrack, VS Code, Cursor

**node_modules (inactive):**
- Scan workspace directory for all `node_modules` folders
- A project is "inactive" if its `.git` directory shows no commits in the last 4 weeks (`git log -1 --since="4 weeks ago"`)
- Non-git directories with `node_modules` are always considered inactive
- If git is not installed, treat all projects as inactive (dev workstation without git is unusual but possible)
- Only report top-level `node_modules` per project (not nested ones)
- Minimum size threshold: 10 MB. Skip smaller `node_modules` to avoid report clutter.

**npm/pnpm/yarn cache:**
- npm: check `~/.npm/_cacache` size directly (NOT `npm cache ls` — removed in npm v5+). Clean with `npm cache clean --force`
- pnpm: `pnpm store path` → check size, `pnpm store prune` to clean. Skip if pnpm not installed.
- yarn v1 (Classic): `yarn cache dir` → check size, `yarn cache clean` to clean. Skip if yarn not installed.
- yarn v2+ (Berry): uses `.yarn/cache` per-project, `yarn cache clean --all` to clean. Detect via `yarn --version`.
- **Skip any tool that is not installed** — check with `command -v` before running.

**pip cache:**
- `pip cache info` for size, `pip cache purge` to clean
- Skip if pip not installed.

**Claude Code debris:**
- `~/.claude/debug/*` — debug logs, always safe
- `~/.claude/file-history/*` — file edit backups, always safe
- `~/.claude/telemetry/*` — telemetry data, always safe
- `~/.claude/projects/*/*.jsonl` — session log files older than 4 weeks (by mtime). Match `*.jsonl` directly under each project directory.
- Note: on Windows, file copy/move operations can reset mtime. This is an acceptable trade-off — worst case, some old sessions survive an extra cycle.

**Crash dumps:**
- Windows: `~/AppData/Local/CrashDumps/`
- macOS: `~/Library/Logs/DiagnosticReports/`
- Linux: `/var/crash/` and `~/.local/share/apport/` (Ubuntu/Debian)

**Build artifacts (inactive projects only):**
- Same inactivity check as node_modules (no git commits in 4 weeks)
- Targets: `.next/`, `.turbo/`, `.parcel-cache/`, `.vite/`
- `dist/` — only if listed in the project's `.gitignore`. Many projects commit `dist/` as published output; never delete committed directories.

**Docker:**
- `docker system df` for size info
- Clean with `docker image prune` (dangling images only) and `docker builder prune` (build cache)
- Do NOT use `docker system prune` — it also removes stopped containers which users may want to keep
- Skip if Docker is not installed or daemon is not running (`docker info` fails)

**App caches (macOS + Linux):**
- macOS: scan `~/Library/Caches/` for directories >50 MB
- Linux: scan `~/.cache/` for directories >50 MB
- Report app name and size

## Interaction Flow

### Step 1: Detect Platform

```bash
uname -s
```
- `MINGW64_NT*` / `MSYS*` → Windows (use PowerShell for folder sizes)
- `Darwin` → macOS (use `du`)
- `Linux` → Linux (use `du`)

### Step 2: Scan

Run all applicable category scans in parallel. Use PowerShell temp scripts on Windows (faster on NTFS), `du -sh` on Mac/Linux.

**Workspace root detection:** Use the project root that Claude Code is running in (the directory containing `.claude/` or the current working directory). For node_modules and build artifact scanning, scan this workspace root recursively.

**Disk space reporting:** Report the drive/partition containing the workspace root. On Windows, extract the drive letter from the workspace path and pass it to `Get-PSDrive`.

Show progress as each category completes:

```
Scanning... [1/7] Squirrel old versions ✓  [2/7] node_modules...
```

**Missing tools:** If a tool is not installed (docker, pip, pnpm, yarn), silently skip that category. Use `command -v <tool>` to check before running.

### Step 3: Report

Display disk usage header and categorized table:

```
Disk: 12GB free / 120GB total (90%)

 #  Category                  Items                              Size
 1  Squirrel old versions     Slack, Discord, Figma (+2 more)    1.3 GB
 2  node_modules (inactive)   harmonica-web-app, gov-acc-site    1.0 GB
 3  npm cache                 ~/.npm/_cacache                    2.2 GB
 4  Claude Code debris        debug (242 files), telemetry       224 MB
 5  pip cache                 ~/pip/cache                        100 MB
 6  Crash dumps               CrashDumps (3 files)                73 MB
 7  Build artifacts           .next in 2 projects                 45 MB
                                                         Total: 4.9 GB
```

Only show categories that found reclaimable items. Skip categories with 0 findings. **Numbers in the table are sequential (1, 2, 3...) based on what's shown**, not fixed category IDs. This keeps the selection step simple.

### Step 4: Select

Ask user which categories to clean:

> "Which categories to clean? Enter numbers (e.g., `1,2,3`), `all`, or `none` to cancel."

If `--dry-run` was passed, skip this step and stop after the report.

### Step 5: Execute

For each selected category:
1. Show what's being deleted
2. Execute the deletion
3. Show confirmation with amount freed

**Partial failure handling:** If cleaning one category fails (e.g., Docker daemon stopped, permission denied), log the error, continue with remaining categories, and include failures in the summary.

### Step 6: Summary

Show before/after disk space comparison:

```
Done! Freed 4.2 GB (12 GB → 16.2 GB free, 87%)
```

If any categories failed, list them:

```
Failed: Docker (daemon not running)
```

## Cross-Platform Paths

| Resource | Windows | macOS | Linux |
|----------|---------|-------|-------|
| Disk space | PowerShell `Get-PSDrive` | `df -h /` | `df -h /` |
| Folder sizes | PowerShell `Get-ChildItem` | `du -sh` | `du -sh` |
| Squirrel apps | `~/AppData/Local/*/app-*` | N/A | N/A |
| App caches | N/A (covered by Squirrel) | `~/Library/Caches/` | `~/.cache/` |
| npm cache | `npm cache clean --force` | same | same |
| pip cache | `pip cache purge` | same | same |
| Crash dumps | `~/AppData/Local/CrashDumps` | `~/Library/Logs/DiagnosticReports` | `/var/crash/`, `~/.local/share/apport/` |
| Claude Code | `~/.claude/` | `~/.claude/` | `~/.claude/` |

## Repo Structure

```
agentic-cleanup/
  cleanup.md              # runtime-neutral slash command
  install.sh
  install.ps1
  install-manifest.sha256
  scripts/                # Windows helpers and structured contracts
  README.md
  docs/
    2026-03-11-cleanup-design.md   # this file
```

The command remains the core product. Installers publish it to Claude Code and OpenCode V2 while sharing one verified helper/contract payload.

## Safety

- **Never delete anything without user selection.** Report first, act second.
- **Squirrel cleanup:** Only delete old versions, always keep the newest `app-*` directory.
- **node_modules/build artifacts:** Only in projects inactive for 4+ weeks. Everything is recoverable via `npm install` / rebuild.
- **dist/ directories:** Only delete if gitignored. Never delete committed `dist/` folders.
- **Caches:** All package manager caches are recoverable (re-downloaded on demand).
- **Claude Code:** Never touch `projects/*/memory/`, `commands/`, `skills/`, `settings*.json`, or `history.jsonl`. Only debris (debug, telemetry, file-history, old session logs).
- **Docker:** Only prune dangling images and build cache. Never remove stopped containers or volumes.
- **Missing tools:** Silently skip categories when the required tool is not installed. Never error out.
- **Partial failures:** Continue with remaining categories if one fails. Report failures in summary.
