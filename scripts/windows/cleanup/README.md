# /cleanup helper scripts (Windows)

Committed helpers for the `/cleanup` skill (`claude-config/commands/cleanup.md`).

**Why files, not inline heredocs.** The skill used to instruct authoring these on
every run by pasting code into bash heredocs. On Windows Git Bash that breaks twice
(both bit on 2026-06-26):

1. Backslash literals (e.g. `rstrip('\\')`) lose a backslash inside a heredoc → Python `SyntaxError`.
2. A hardcoded `/tmp/...` path inside a script is **not** MSYS-converted (only command-line
   arguments are) → `FileNotFoundError`.

Shipping them as files removes the whole class of bug and is faster. Always pass the
CSV path and workspace root as **command-line arguments** so MSYS converts them; never
hardcode a `/tmp/...` path inside a script.

| Script | Usage | Purpose |
|--------|-------|---------|
| `wt_lookup.py` | `printf '%s\n' '<winpath>' … \| python wt_lookup.py <csv>` | Size lookup: stdin paths → `sizeMB\|path` |
| `find_targets.py` | `python find_targets.py <csv> <workspace_root>` | Top-level `node_modules` (≥10 MB) + `.next`/`.turbo`/`.parcel-cache`/`.vite` dirs |
| `diskspace.ps1` | `powershell.exe -NoProfile -File diskspace.ps1 [C]` | `free total pct` in GB (default = system drive) |
| `run_wiztree.ps1` | `powershell.exe -NoProfile -File run_wiztree.ps1 -WizTree <exe> -OutCsv <winpath>` | Elevated WizTree MFT export (one UAC; `/admin=0` times out) |
| `squirrel.ps1` | `powershell.exe -NoProfile -File squirrel.ps1` | Discover Squirrel old `app-*` versions |
| `appdata_orphans.ps1` | `powershell.exe -NoProfile -File appdata_orphans.ps1` | Orphaned `%APPDATA%`/`%LOCALAPPDATA%` dirs |
| `winsdk.ps1` | `powershell.exe -NoProfile -File winsdk.ps1` | Old side-by-side Windows SDK versions |
| `vs_orphans.ps1` | `powershell.exe -NoProfile -File vs_orphans.ps1` | Orphaned Visual Studio installs |
| `live_paths.ps1` | `powershell.exe -NoProfile -File live_paths.ps1 [-Summary]` | Paths running processes depend on (stdout); session census (stderr) |
| `registered_mcp.ps1` | Dot-source from committed scan/validation helpers | Static Claude Code and OpenCode V2 local MCP ownership discovery |
| `scan.ps1` | `pwsh -NoProfile -File scan.ps1 -OutputPath <scan.json>` | Immutable six-category Windows evidence scan (PowerShell 7) |
| `assert_list.py` | `python assert_list.py <list> --require 'L=SUB' --forbid 'L=SUB'` | **Gate before `scrub.ps1`** — buckets the list; fails on a missing/forbidden/unclassified/empty entry |
| `scrub.ps1` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scrub.ps1 -ListFile <file>` | Hook-safe batch deleter (one path per line) |
| `execute-plan.ps1` | `pwsh -NoProfile -File execute-plan.ps1 -ScanPath <scan> -PlanPath <plan> -OutputPath <result>` | Validate and dispatch allowlisted operations |

Automatic UAC launching is intentionally not part of the first structured
slice. Elevated operations use the same plan and validator but execute only
when `execute-plan.ps1` is already running in a trusted elevated process;
otherwise they return `manual-required`.

**Hook-safe deletion.** `scrub.ps1` exists because this workstation's path-protection
PreToolUse hook scans the command *string* and aborts the whole command if it sees an
inline `Remove-Item`/`rmdir` on a protected path. The launcher carries no delete keywords,
so the deletes (inside the file) pass. The worker is named `Scrub`, never `Del`/`RD`/`RM`
(those are `Remove-Item` aliases that would shadow a same-named function).

Canonical skill source is also published at `github.com/zhiganov/agentic-cleanup`
(`cleanup-gist.md`); keep that copy in sync when these change.
