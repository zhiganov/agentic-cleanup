# CLAUDE.md

This file provides guidance to coding agents working in this repository.

## Overview

Source repository and distribution for the `/cleanup` command and `agentic-cleanup` skill for Claude Code and OpenCode V2. It scans a developer workstation for reclaimable disk space across 32 categories and lets users selectively clean them. Cross-platform: Windows, macOS, Linux. Uses WizTree for instant NTFS scanning on Windows when available.

Repo: `zhiganov/agentic-cleanup`. Tagline: "Safe disk cleanup for coding agents."

## Architecture

The thin runtime-neutral `cleanup.md` delegates to the short governing workflow in `skills/agentic-cleanup/SKILL.md`, with on-demand platform/category recipes in `references/workflow.md`. On Windows the skill is backed by committed Python and PowerShell helpers under `scripts/windows/cleanup/`. There is no build step or package dependency; Windows uses system Python and PowerShell, while installation uses standard shell and SHA-256 utilities.

```
cleanup.md                    ← thin runtime-neutral slash command
skills/agentic-cleanup/       ← full agent-interpreted workflow
scripts/windows/cleanup/      ← committed Windows helper scripts (scan + hook-safe delete)
scripts/cleanup/              ← versioned scan/plan/result contracts + policies
install.sh / install.ps1      ← install selected runtime commands + one shared payload
cleanup-gist.md               ← slimmer, harness-agnostic portable variant (Unix-first)
docs/                          ← spec and implementation plan
```

## How the Command Works

The skill instructs the active coding agent through 7 steps:
1. Detect platform (`uname -s`) and measure disk space
2. Detect workspace root — the **outermost** ancestor containing `.claude/`, `.opencode/`, `opencode.json`, or `opencode.jsonc`, **excluding `$HOME`**
2.5. **WizTree fast scan** (Windows only) — if WizTree is installed, export CSV for instant size lookups; also accepts manually-exported CSVs
3. Scan up to 32 categories in parallel and classify whole-drive or scoped top-consumer outliers beyond the fixed list — uses WizTree data when available on Windows, falls back to bounded platform-native scans. On Linux/macOS, categories are grouped into Cross-platform / Windows-only / Unix sections; runtime guards skip non-applicable ones.
4. Display report table sorted by size
5. User selects categories to clean (or `--dry-run` stops here)
6. Refresh selected evidence and execute cleanup — elevated operations require a trusted elevated worker
7. Show before/after summary

## Key Design Decisions

- **WizTree acceleration:** Reads NTFS MFT directly, replacing dozens of slow `Get-ChildItem -Recurse` calls with instant CSV lookups via a Python helper script.
- **Evidence-first outliers:** `find_outliers.py` turns a whole-drive WizTree export into non-overlapping material hotspots. The skill classifies these separately before any candidate is offered; fixed categories are safety policies, not discovery limits. `hiberfil.sys` is suppressed at source and never proposed.
- **Committed helper scripts (Windows):** The scan/delete helpers are committed files, not inline heredocs. Resolve the skill, helpers and contracts from this repository or one verified installed payload under `${XDG_DATA_HOME:-~/.local/share}/agentic-cleanup/`. Never fall back to another project's copy or mix payload roots. Use unique per-run scratch and remove only that run's artifacts.
- **Structured contract pipeline:** `scripts/cleanup/` owns immutable evidence,
  selected plans, policy/executor allowlists, refreshed validation, and result
  schemas. `scripts/windows/cleanup/scan.ps1` and `execute-plan.ps1` are the
  Windows producer/executor boundary. The opt-in `--structured-preview` requires
  PowerShell 7 while migration from the prose path is incomplete.
- **Installed release integrity:** `install-manifest.sha256` binds the installed
  command, skill, helpers, contracts, schemas, and policy. Both installers stage
  and verify all files, copy the command and skill first, and publish the manifest last so an
  interrupted update fails closed instead of leaving an undetectable mixed set.
- **Runtime selection:** `AGENTIC_CLEANUP_RUNTIME=claude|opencode|all` controls which command/skill pairs an installer publishes. Single-runtime installation never inspects the unselected runtime. The skill uses `OPENCODE_TERMINAL` or `CLAUDECODE` to verify only its active runtime pair against the shared manifest.
- **`scrub.ps1` for hook-safe Windows deletes:** A path-protection hook aborts any command string containing an inline `Remove-Item`/`rmdir` on a protected path. `scrub.ps1` takes a list file and does the deletes from inside the script (the launcher carries no delete keywords); its worker function is `Scrub`, never `Del`/`RD`/`RM` (those are `Remove-Item` aliases that shadow same-named functions).
- **`npm-cache` is NOT a `scrub.ps1` target — `_npx` hosts running MCP servers.** `%LOCALAPPDATA%\npm-cache\_npx\` is where `npx -y <pkg>` materialises packages, so on a Claude Code machine live MCP servers (harmonica-mcp, context7, shadcn…) execute from inside npm-cache, once per running session. A whole-dir `rmdir /s /q` deletes their code mid-flight. Only `npm cache clean --force` is safe (prunes `_cacache`, leaves `_npx`) — slower, and that's the price. 2026-07-16: scrub returned `Access is denied` **because** two sessions held it; the lock was the only thing preventing the damage.
- **Four temp exclusions:** `agentic-cleanup`, legacy `claude-cleanup`, Claude Code's `claude` runtime scratch, and OpenCode's `opencode` runtime scratch. Deleting an older cleanup run's scratch or active agent scratch can kill in-flight work.
- **Accounting: pre-deletion snapshot + hardlink caveat.** The summary's "before" is snapshotted immediately before deletion (not at scan start — the run itself writes the ~200 MB CSV in between). WizTree `node_modules`/pnpm sizes are logical and overlap via hardlinks, so measured reclaim can be far below selected-total.
- **Trusted elevated workers:** Elevated operations require an already elevated trusted process or return `manual-required`. Workers own structured results; `-Verb RunAs` is incompatible with stdout redirection, and missing output never proves UAC was declined.
- **Independent file evidence:** `find_outliers.py --files --json` does not group nested files; `file_audit.py` offers bounded metadata-only selected known-folder/root audits. Reports distinguish logical size, allocation, unknown unique recovery, and signed net change.
- **Exact cache and log scopes:** `build-cache-contents` clears only approved `.next/cache` contents, preserving roots/siblings. `maintenance.ps1` guards old exact log files and one supported DISM pass, never wildcard current-log deletion, `/ResetBase`, reboot or service killing.
- **Inactivity = no git commits in 4 weeks.** Non-git directories are always considered inactive.
- **`dist/` is only cleaned if gitignored** — many projects commit `dist/` as published output.
- **Docker: `docker image prune` + `docker builder prune` only** — never `docker system prune` (removes stopped containers).
- **Claude Code safety:** Never touch `memory/`, `commands/`, `skills/`, `settings*.json`, `history.jsonl`.
- **Hook-safe deletion (Linux/macOS):** Many safety hooks block `rm -rf` against paths starting with `/` or `~`. Use `find <path> -mindepth 1 -delete && rmdir <path>` instead — same result, no pattern collision, errors on typos rather than recursing.
- **Inactivity check resolves repo root:** For nested packages in monorepos (e.g. `repo/server/node_modules` with `.git` at `repo/`), the inactivity check runs `git rev-parse --show-toplevel` before testing the log window. Testing the subpackage path directly silently false-positives.
- **Orphan-scan filter chain (both platforms):** 4-layer filter — allowlist + `command -v` active-binary + 30-day mtime + token-boundary package match. Substring matching produces real-world false-negatives (e.g. `zenity` would swallow `zen` and skip a real orphan), so the match requires `pkg == name` or `pkg == name-*` or `pkg == *-name` etc.
- **Hardlink/CAS caveat:** Bun and pnpm caches use content-addressed stores with hardlinks into project `node_modules`. `du` reports apparent size from the cache's perspective, but `df` reclaims only when the last hardlink is gone — pair cache cleanup with the `node_modules (inactive)` category for real reclaim.

## Modifying the Workflow

When editing `skills/agentic-cleanup/SKILL.md`:
- Instructions must be precise because coding agents interpret them literally
- Platform guards (`Skip if platform is not windows`) must be on every platform-specific category
- Tool checks (`command -v <tool>`) must precede any tool usage
- Every category needs: scan instructions, size collection, and a clean command in the Step 6 table
- WizTree-accelerated categories must have a "Fallback:" path for when WizTree isn't available
- **Do NOT test installers against the real user directories.** Set temporary `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` values so global command copies cannot shadow canonical sources.
- Keep `cleanup.md` thin: it may only delegate to the skill and forward `$ARGUMENTS`; workflow instructions belong in the skill.
- **Sole source owner is `zhiganov/agentic-cleanup`.** New cleanup commands, skills, helpers, contracts, tests, installers and product issues belong here. The former claude-config-canonical arrangement is superseded. Do not duplicate implementation there or open a companion PR; existing copies are legacy consumers, not sources. If another instruction still claims a different owner, raise the conflict before editing, rather than continuing the old duplication.
- **Release integrity stays local to this product.** Keep both installer fetch lists and `install-manifest.sha256` complete. Normalize LF/CRLF before hashing repository files; installed release files and the active runtime command/skill/reference must match the verified release.
- `python scripts/cleanup/update-manifest.py` regenerates this repository's normalized release manifest; `--check` verifies it without writing. It never copies code across repositories, installs runtime copies or cleans the workstation. Update both installers when the release inventory changes.
- **`grep -i -F` aborts** (SIGABRT, exit 134) on Git-for-Windows GNU grep 3.0 — any input, even `echo hello | grep -c -i -F hello`. Use `-F` without `-i`; do case-insensitive fixed-string matching in Python or PowerShell. An abort emits nothing, and nothing looks exactly like "no matches".
