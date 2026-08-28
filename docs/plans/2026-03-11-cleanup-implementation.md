# /cleanup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a publishable `/cleanup` slash command that scans a developer workstation for reclaimable disk space and lets users selectively clean categories.

**Historical note:** This plan records the original Claude Code-only implementation. The current package uses one runtime-neutral `cleanup.md`, dual Claude Code/OpenCode installers, and a shared agent-neutral data directory; see the repository README.

**Architecture:** Single markdown file (`cleanup.md`) containing step-by-step instructions for a coding agent. No runtime code — the agent interprets the instructions and runs bash/PowerShell commands directly.

**Tech Stack:** Markdown (slash command), Bash, PowerShell (Windows), Git (repo publishing)

**Spec:** `docs/2026-03-11-cleanup-design.md`

---

## File Structure

```
agentic-cleanup/
  cleanup.md                # runtime-neutral slash command
  install.sh                # Unix install script (alternative to skillsadd)
  install.ps1               # Windows install script (alternative to skillsadd)
  README.md
  LICENSE
  docs/
    2026-03-11-cleanup-design.md    # spec (already exists)
    plans/
      2026-03-11-cleanup-implementation.md  # this file
```

---

## Chunk 1: Setup and Slash Command

### Task 1: Initialize git repo

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Init repo**

```bash
cd ~/claude-project/agentic-cleanup
git init
```

- [ ] **Step 2: Create .gitignore**

```
node_modules/
```

- [ ] **Step 3: Initial commit with spec and plan**

```bash
git add docs/ .gitignore
git commit -m "docs: add spec and implementation plan"
```

### Task 2: Write the cleanup.md slash command

**Files:**
- Create: `cleanup.md`

This is the core deliverable. The entire command is a single markdown file with instructions for Claude Code. It must be detailed and precise because Claude interprets these instructions literally.

- [ ] **Step 1: Write command header, argument parsing, and platform detection**

Create `cleanup.md` with:

```markdown
# Developer Workstation Disk Cleanup

Scan the workstation for reclaimable disk space, report findings, let the user select categories to clean, and execute.

## Arguments

- `$ARGUMENTS` — optional flags

Parse `$ARGUMENTS`: if it contains `--dry-run`, set dry_run mode (report only, skip selection/deletion).

## Instructions

### Step 1: Detect Platform and Disk Space

Run `uname -s` and determine platform:
- Output starts with `MINGW` or `MSYS` → **windows**
- Output is `Darwin` → **macos**
- Output is `Linux` → **linux**
```

Include disk space measurement:
- **Windows:** Write a PowerShell temp script using `Get-PSDrive` for the drive containing the current directory
- **macOS/Linux:** `df -h /` — parse free space and total

Store the "before" free space for the final summary.

- [ ] **Step 2: Write workspace root detection**

Add instructions to determine the workspace root for scanning node_modules and build artifacts:
- Use the directory containing `.claude/` or the current working directory
- Store this path for use in categories 2 and 7

- [ ] **Step 3: Write scan instructions — Category 1: Squirrel old versions (Windows only)**

```markdown
### Category: Squirrel Old Versions (Windows only)

Skip if platform is not **windows**.

Scan for Electron apps with old versions:
```

Write a PowerShell temp script that:
- Scans `$env:LOCALAPPDATA` for directories containing `Update.exe`
- Within each, finds `app-*` subdirectories
- If more than one version exists, sums the size of all except the newest
- Reports: app name, old version names, total reclaimable size

- [ ] **Step 4: Write scan instructions — Category 2: node_modules (inactive)**

Instructions for all platforms:
- Find all top-level `node_modules` directories under the workspace root
- For each parent project: check if it has `.git` and if `git log -1 --since="4 weeks ago"` returns commits
- If git not installed (`command -v git` fails), treat all as inactive
- Non-git directories are always inactive
- Skip `node_modules` smaller than 10 MB
- Use PowerShell `Get-ChildItem` on Windows, `du -sh` on Mac/Linux for sizes
- Report: project name, size

- [ ] **Step 5: Write scan instructions — Category 3: Package manager caches**

Instructions for all platforms:
- **npm:** Check if `command -v npm` succeeds. Measure `~/.npm/_cacache` size directly (NOT `npm cache ls`). On Windows the path is `~/AppData/Local/npm-cache`.
- **pnpm:** Check `command -v pnpm`. Run `pnpm store path`, measure that directory's size. Skip if pnpm not installed.
- **yarn:** Check `command -v yarn`. Run `yarn --version` to detect v1 vs v2+. For v1: `yarn cache dir` → measure size. For v2+: note per-project `.yarn/cache`. Skip if yarn not installed.
- Report: tool name, cache path, size for each installed tool

- [ ] **Step 6: Write scan instructions — Category 4: pip cache**

- Check `command -v pip` (or `pip3`). Skip if not installed.
- Run `pip cache info` to get cache size
- Report: cache size

- [ ] **Step 7: Write scan instructions — Category 5: Claude Code debris**

Instructions for all platforms:
- Measure sizes of: `~/.claude/debug/`, `~/.claude/file-history/`, `~/.claude/telemetry/`
- Count `.jsonl` files older than 4 weeks in `~/.claude/projects/*/` (use `find -mtime +28` on Mac/Linux, PowerShell on Windows)
- **SAFETY: Never touch** `projects/*/memory/`, `commands/`, `skills/`, `settings*.json`, `history.jsonl`
- Report: item breakdown (debug X files, telemetry Y MB, N old sessions), total size

- [ ] **Step 8: Write scan instructions — Category 6: Crash dumps**

Platform-specific paths:
- **Windows:** `~/AppData/Local/CrashDumps/`
- **macOS:** `~/Library/Logs/DiagnosticReports/`
- **Linux:** `/var/crash/` and `~/.local/share/apport/`
- Measure total size, skip if directory doesn't exist
- Report: file count, total size

- [ ] **Step 9: Write scan instructions — Category 7: Build artifacts (inactive)**

Instructions for all platforms:
- Same inactivity check as node_modules (category 2)
- Look for: `.next/`, `.turbo/`, `.parcel-cache/`, `.vite/`
- For `dist/`: only include if it appears in the project's `.gitignore`
- Skip projects that are active (recent git commits)
- Report: project name, artifact type, size

- [ ] **Step 10: Write scan instructions — Category 8: Docker**

- Check `command -v docker` and `docker info` (daemon running). Skip if either fails.
- Run `docker system df` to get reclaimable space for images and build cache
- Report: dangling images size, build cache size

- [ ] **Step 11: Write scan instructions — Category 9: App caches (macOS + Linux)**

- **macOS:** Scan `~/Library/Caches/` for directories >50 MB
- **Linux:** Scan `~/.cache/` for directories >50 MB
- Skip on Windows (covered by Squirrel category)
- Report: app name, size for each large cache

- [ ] **Step 12: Write report instructions**

Instruct Claude to assemble and display:
- Disk usage header: `Disk: XGB free / YGB total (Z%)`
- Table with columns: #, Category, Items, Size
- Only rows with findings (>0 size)
- Sequential numbering (1, 2, 3... renumbered based on shown rows)
- Sorted by size descending
- Total row at bottom

- [ ] **Step 13: Write selection and execution instructions**

Instruct Claude to:
- If `--dry-run` was passed, stop after the report
- Otherwise ask: `Which categories to clean? Enter numbers (e.g., 1,2,3), all, or none to cancel.`
- For each selected category, execute the specific clean command:
  - Squirrel: `rm -rf` each old `app-*` directory
  - node_modules: `rm -rf` each inactive project's `node_modules/`
  - npm cache: `npm cache clean --force`
  - pnpm cache: `pnpm store prune`
  - yarn v1 cache: `yarn cache clean`
  - yarn v2+ cache: `yarn cache clean --all`
  - pip cache: `pip cache purge`
  - Claude Code: `rm -rf ~/.claude/debug/* ~/.claude/file-history/* ~/.claude/telemetry/*` and `find ~/.claude/projects -name "*.jsonl" -mtime +28 -delete`
  - Crash dumps: `rm -rf` contents of platform-specific paths
  - Build artifacts: `rm -rf` each artifact directory
  - Docker: `docker image prune -f` and `docker builder prune -f`
  - App caches: `rm -rf` each large cache directory
- If any cleanup fails, log the error and continue with remaining categories
- After all selected categories are cleaned, re-measure disk space
- Show summary: `Done! Freed X.X GB (before → after free, percentage)`
- If any categories failed, list them: `Failed: category (reason)`

- [ ] **Step 14: Review the complete command file**

Read the full `cleanup.md` and verify:
- All 9 categories covered with correct platform guards
- Safety rules from spec are embedded
- Cross-platform paths match the spec
- Missing tool handling is explicit (`command -v` checks)
- Flow: detect → scan → report → select → execute → summary
- `$ARGUMENTS` parsing for `--dry-run` is correct

- [ ] **Step 15: Commit**

```bash
git add cleanup.md
git commit -m "feat: add /cleanup slash command with 9 scan categories"
```

---

## Chunk 2: Install Scripts, README, Publishing

### Task 3: Write install scripts and README

**Files:**
- Create: `install.sh`
- Create: `install.ps1`
- Create: `README.md`
- Create: `LICENSE`

- [ ] **Step 1: Write install.sh**

```bash
#!/bin/bash
set -e

REPO_URL="https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master"
CLAUDE_DIR="$HOME/.claude"

echo "Installing agentic-cleanup..."

mkdir -p "$CLAUDE_DIR/commands"
curl -fsSL "$REPO_URL/cleanup.md" -o "$CLAUDE_DIR/commands/cleanup.md"
echo "✓ Installed cleanup.md → ~/.claude/commands/"

echo ""
echo "Installation complete! Use /cleanup in Claude Code to get started."
```

- [ ] **Step 2: Write install.ps1**

```powershell
$RepoUrl = "https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master"
$ClaudeDir = "$env:USERPROFILE\.claude"

Write-Host "Installing agentic-cleanup..."

New-Item -ItemType Directory -Force -Path "$ClaudeDir\commands" | Out-Null
Invoke-WebRequest -Uri "$RepoUrl/cleanup.md" -OutFile "$ClaudeDir\commands\cleanup.md"
Write-Host "✓ Installed cleanup.md → ~/.claude/commands/"

Write-Host ""
Write-Host "Installation complete! Use /cleanup in Claude Code to get started."
```

- [ ] **Step 3: Write README.md**

Include:
- One-line description: "Safe disk cleanup for coding agents"
- Install instructions: the repository `install.sh` and `install.ps1`
- What it scans (9 categories with brief descriptions)
- Usage: `/cleanup` and `/cleanup --dry-run`
- Platform support: Windows, macOS, Linux
- Example output (the report table from the spec)
- Safety guarantees (report-first, never deletes without selection, keeps newest versions)

- [ ] **Step 4: Write LICENSE (MIT)**

Standard MIT license, copyright 2026 Artem Zhiganov.

- [ ] **Step 5: Commit**

```bash
git add install.sh install.ps1 README.md LICENSE
git commit -m "feat: add install scripts, README, and LICENSE"
```

### Task 4: Test locally and publish

**Files:**
- Modify: `~/cleanup.md` (copy for testing)

- [ ] **Step 1: Install locally for testing**

```bash
cp ~/claude-project/agentic-cleanup/cleanup.md ~/cleanup.md
```

- [ ] **Step 2: Test dry-run mode**

Run `/cleanup --dry-run` in Claude Code. Verify:
- Platform detected correctly
- All applicable categories scan without errors
- Report table renders properly
- Stops after report (no selection prompt)

- [ ] **Step 3: Test full cleanup flow**

Run `/cleanup`. Verify:
- Selection prompt appears after report
- Selecting specific numbers (e.g., `1,3`) works
- `all` and `none` work
- Cleanup executes for selected categories only
- Summary shows before/after disk space

- [ ] **Step 4: Fix any issues found during testing**

Address bugs from steps 2-3. Update `cleanup.md`, re-copy, re-test.

- [ ] **Step 5: Commit fixes (if any)**

```bash
git add -A
git commit -m "fix: address issues found during testing"
```

- [ ] **Step 6: Create GitHub repo and push**

```bash
cd ~/claude-project/agentic-cleanup
gh repo create zhiganov/agentic-cleanup --public --description "Safe disk cleanup for coding agents" --source .
git push -u origin master
```

- [ ] **Step 7: Verify both runtime layouts**

```bash
# Run each installer with temporary CLAUDE_CONFIG_DIR, XDG_CONFIG_HOME,
# and XDG_DATA_HOME values.
```

Verify that `/cleanup` is available in Claude Code and OpenCode V2 after installation.

- [ ] **Step 8: Add to workspace CLAUDE.md**

Add `agentic-cleanup/` to the directory table in root CLAUDE.md:
```
| `agentic-cleanup/` | Published slash command for dev workstation disk cleanup (github.com/zhiganov/agentic-cleanup) |
```

Add `/cleanup` to the custom commands table:
```
| `/cleanup` | Scan workstation for reclaimable disk space — node_modules, caches, old app versions, build artifacts |
```
