# CLAUDE.md

This file provides guidance to coding agents working in this repository.

## Overview

Published runtime-neutral `/cleanup` command for Claude Code and OpenCode V2. It scans a developer workstation for reclaimable disk space across 31 categories and lets users selectively clean them. Cross-platform: Windows, macOS, Linux. Uses WizTree for instant NTFS scanning on Windows when available.

Repo: `zhiganov/agentic-cleanup`. Tagline: "Safe disk cleanup for coding agents."

## Architecture

This is primarily a **slash command repo**. The core product is one runtime-neutral `cleanup.md` containing structured instructions that either supported agent interprets at runtime. On Windows it is backed by committed Python and PowerShell helpers under `scripts/windows/cleanup/`. There is no build step or package dependency; Windows uses system Python and PowerShell, while installation uses standard shell and SHA-256 utilities.

```
cleanup.md                    ← the runtime-neutral slash command
scripts/windows/cleanup/      ← committed Windows helper scripts (scan + hook-safe delete)
scripts/cleanup/              ← versioned scan/plan/result contracts + policies
install.sh / install.ps1      ← install both runtime commands + one shared payload
cleanup-gist.md               ← slimmer, harness-agnostic portable variant (Unix-first)
docs/                          ← spec and implementation plan
```

## How the Command Works

The command instructs the active coding agent through 7 steps:
1. Detect platform (`uname -s`) and measure disk space
2. Detect workspace root — the **outermost** ancestor containing `.claude/`, `.opencode/`, `opencode.json`, or `opencode.jsonc`, **excluding `$HOME`**
2.5. **WizTree fast scan** (Windows only) — if WizTree is installed, export CSV for instant size lookups; also accepts manually-exported CSVs
3. Scan up to 31 categories in parallel (only those matching the detected platform fire) — uses WizTree data when available on Windows, falls back to PowerShell. On Linux/macOS, categories are grouped into Cross-platform / Windows-only / Unix sections; runtime guards skip non-applicable ones.
4. Display report table sorted by size
5. User selects categories to clean (or `--dry-run` stops here)
6. Execute cleanup — elevated categories batched into single UAC prompt
7. Show before/after summary

## Key Design Decisions

- **WizTree acceleration:** Reads NTFS MFT directly, replacing dozens of slow `Get-ChildItem -Recurse` calls with instant CSV lookups via a Python helper script.
- **Committed helper scripts (Windows):** The scan/delete helpers are committed files, not inline heredocs. The command resolves them from the repository, the synced `claude-config` workspace, or `${XDG_DATA_HOME:-~/.local/share}/agentic-cleanup/scripts/windows/cleanup/`. Only the WizTree CSV scratch lives in `/tmp/agentic-cleanup/` and is removed in Step 7.
- **Structured contract pipeline:** `scripts/cleanup/` owns immutable evidence,
  selected plans, policy/executor allowlists, refreshed validation, and result
  schemas. `scripts/windows/cleanup/scan.ps1` and `execute-plan.ps1` are the
  Windows producer/executor boundary. The opt-in `--structured-preview` requires
  PowerShell 7 while migration from the prose path is incomplete.
- **Installed release integrity:** `install-manifest.sha256` binds the installed
  command, helpers, contracts, schemas, and policy. Both installers stage and
  verify all files, copy the command first, and publish the manifest last so an
  interrupted update fails closed instead of leaving an undetectable mixed set.
- **`scrub.ps1` for hook-safe Windows deletes:** A path-protection hook aborts any command string containing an inline `Remove-Item`/`rmdir` on a protected path. `scrub.ps1` takes a list file and does the deletes from inside the script (the launcher carries no delete keywords); its worker function is `Scrub`, never `Del`/`RD`/`RM` (those are `Remove-Item` aliases that shadow same-named functions).
- **`npm-cache` is NOT a `scrub.ps1` target — `_npx` hosts running MCP servers.** `%LOCALAPPDATA%\npm-cache\_npx\` is where `npx -y <pkg>` materialises packages, so on a Claude Code machine live MCP servers (harmonica-mcp, context7, shadcn…) execute from inside npm-cache, once per running session. A whole-dir `rmdir /s /q` deletes their code mid-flight. Only `npm cache clean --force` is safe (prunes `_cacache`, leaves `_npx`) — slower, and that's the price. 2026-07-16: scrub returned `Access is denied` **because** two sessions held it; the lock was the only thing preventing the damage.
- **Three migration-safe temp exclusions:** `agentic-cleanup`, legacy `claude-cleanup`, and Claude Code's `claude` runtime scratch. Deleting an older cleanup run's scratch or the active agent scratch can kill in-flight work.
- **Accounting: pre-deletion snapshot + hardlink caveat.** The summary's "before" is snapshotted immediately before deletion (not at scan start — the run itself writes the ~200 MB CSV in between). WizTree `node_modules`/pnpm sizes are logical and overlap via hardlinks, so measured reclaim can be far below selected-total.
- **Single UAC prompt:** All elevated operations (system logs, VS cache, kernel reports, delivery optimization) batched into one PowerShell script run with `-Verb RunAs`.
- **Inactivity = no git commits in 4 weeks.** Non-git directories are always considered inactive.
- **`dist/` is only cleaned if gitignored** — many projects commit `dist/` as published output.
- **Docker: `docker image prune` + `docker builder prune` only** — never `docker system prune` (removes stopped containers).
- **Claude Code safety:** Never touch `memory/`, `commands/`, `skills/`, `settings*.json`, `history.jsonl`.
- **Hook-safe deletion (Linux/macOS):** Many safety hooks block `rm -rf` against paths starting with `/` or `~`. Use `find <path> -mindepth 1 -delete && rmdir <path>` instead — same result, no pattern collision, errors on typos rather than recursing.
- **Inactivity check resolves repo root:** For nested packages in monorepos (e.g. `repo/server/node_modules` with `.git` at `repo/`), the inactivity check runs `git rev-parse --show-toplevel` before testing the log window. Testing the subpackage path directly silently false-positives.
- **Orphan-scan filter chain (both platforms):** 4-layer filter — allowlist + `command -v` active-binary + 30-day mtime + token-boundary package match. Substring matching produces real-world false-negatives (e.g. `zenity` would swallow `zen` and skip a real orphan), so the match requires `pkg == name` or `pkg == name-*` or `pkg == *-name` etc.
- **Hardlink/CAS caveat:** Bun and pnpm caches use content-addressed stores with hardlinks into project `node_modules`. `du` reports apparent size from the cache's perspective, but `df` reclaims only when the last hardlink is gone — pair cache cleanup with the `node_modules (inactive)` category for real reclaim.

## Modifying the Command

When editing `cleanup.md`:
- Instructions must be precise because coding agents interpret them literally
- Platform guards (`Skip if platform is not windows`) must be on every platform-specific category
- Tool checks (`command -v <tool>`) must precede any tool usage
- Every category needs: scan instructions, size collection, and a clean command in the Step 6 table
- WizTree-accelerated categories must have a "Fallback:" path for when WizTree isn't available
- **Do NOT test installers against the real user directories.** Set temporary `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` values so global command copies cannot shadow canonical sources.
- **Canonical is `zhiganov/claude-config`** (`commands/cleanup.md` + `scripts/windows/cleanup/` + `scripts/cleanup/`) — that workspace is where the command is iterated. This repo is the **published** copy that `install.sh` serves. Sync canonical → here and keep the `install.sh`/`install.ps1` fetch lists current; a helper that is not in both lists is a script no installed user ever downloads. Step 1 of the command hash-compares the two checkouts and refuses to run on drift.
- **Compare Windows checkouts with `diff --strip-trailing-cr`.** Both repos are `core.autocrlf=true` with no `.gitattributes`, so a working-tree file is LF or CRLF depending only on whether it arrived via `git checkout` or a copy — and git calls both clean. Byte-exact `cmp` is only a fallback on platforms whose `diff` lacks the option and whose checkouts remain LF.
- **`grep -i -F` aborts** (SIGABRT, exit 134) on Git-for-Windows GNU grep 3.0 — any input, even `echo hello | grep -c -i -F hello`. Use `-F` without `-i`; do case-insensitive fixed-string matching in Python or PowerShell. An abort emits nothing, and nothing looks exactly like "no matches".
