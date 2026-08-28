# Developer Workstation Cleanup

Drop this into any LLM with shell access (Claude Code, Cursor, Codex, ChatGPT with code interpreter, etc.) and it will scan your machine for reclaimable disk space, report findings, let you pick what to delete, and execute the cleanup. Designed for macOS / Linux dev laptops; Windows paths in the appendix.

The goal: reclaim space without trashing anything you care about. Each category below is something the LLM can detect, measure, and *propose* — you decide what gets deleted.

## The algorithm

1. **Measure.** Run `df -h /` (or the equivalent) and store the "before" free-space number.
2. **Detect workspace root.** Walk up from the current directory until you find a marker (`.git`, `package.json`, or a known config dir). This becomes the scan root for project-scoped categories.
3. **Scan each category** below. Skip ones that don't apply (tool not installed, path doesn't exist, total under the threshold). For each, collect: a short label, the matching items, total size, and the paths needed to delete them.
4. **Build a table** sorted by size descending. Number rows 1..N. Show each row's category, a 2-3 item preview, and size. Print disk free/total/% at the top.
5. **Ask which to clean.** Wait for the user to pick numbers, `all`, or `none`. Do not assume.
6. **Execute** only the selected categories. Show progress per category. Track failures.
7. **Re-measure** and print "Freed X GB ([before] → [after])". List any categories that failed.

That's the whole shape. Below are the categories worth checking and the rules that keep the LLM from doing something dumb.

## Categories worth checking

For each category: how to detect/measure it, the skip threshold, and the clean command. Skip the entire category if it can't find anything substantial.

### Package manager caches

Almost always safe to clean — these are pure caches that the tool will refill on demand.

- **npm.** Path: `~/.npm/_cacache` (Unix) / `~/AppData/Local/npm-cache` (Windows). Measure with `du -sm`. Clean: `npm cache clean --force`.
- **pnpm.** Get the store path with `pnpm store path`, measure it. Clean: `pnpm store prune`.
- **yarn.** Detect version with `yarn --version`. Classic v1: `yarn cache dir` → measure → `yarn cache clean`. Berry (v2+): per-project `.yarn/cache` dirs; `yarn cache clean --all`.
- **pip.** `pip cache info` prints the path and size; `pip cache purge` empties it.
- **cargo.** `~/.cargo/registry/cache` and `~/.cargo/registry/src`. Safe to `rm -rf` — cargo refetches.
- **go.** `go env GOMODCACHE` and `go env GOCACHE`. Clean with `go clean -modcache` and `go clean -cache`.
- **homebrew (macOS).** `brew --cache` shows the path; `brew cleanup -s` is the maintained command.

Threshold: skip a tool if its cache is under ~50 MB or the tool isn't installed.

### Inactive `node_modules`

These accumulate fast and are usually 100 MB - 1 GB each. The rule: find every top-level `node_modules` under the workspace root, then for each one check whether the project is **active**:

- If the project has no `.git/`, it's inactive.
- If `git log -1 --since="4 weeks ago"` returns nothing, it's inactive.
- Otherwise it's active — skip it.

Measure each inactive `node_modules` with `du -sm`. Skip ones under 10 MB. Clean by `rm -rf` on the directory — the user can run `npm install` (or whatever) when they next touch the project.

**Only report top-level `node_modules`** (one per project). Don't recurse into nested ones — they're dependencies of the top-level one and will go with it.

### Build artifacts in inactive projects

Same inactivity check as `node_modules`. In each inactive project, look for:

- `.next/` (Next.js)
- `.turbo/` (Turborepo)
- `.parcel-cache/`
- `.vite/`
- `dist/` — **only if `dist` appears in the project's `.gitignore`.** Many projects commit `dist/` as published output; never delete a committed `dist/`.
- `target/` (Rust) — only if the project hasn't been built recently
- `__pycache__/` and `.pytest_cache/` (Python)

Measure each. Skip the category if total is under 50 MB.

### Docker reclaimable

Skip if `docker` isn't installed or the daemon isn't running. Otherwise `docker system df` reports reclaimable space for dangling images and the build cache.

Clean with `docker image prune -f` and `docker builder prune -f`. **Do not use `docker system prune`** — it also removes stopped containers, which the user may want to keep.

### Crash dumps and core files

- **macOS:** `~/Library/Logs/DiagnosticReports/` accumulates `.ips` crash reports.
- **Linux:** `/var/crash/` and `~/.local/share/apport/` (Ubuntu/Debian). Also any stray `core.*` files in your repos.

Measure and report. Skip if total is under 5 MB. `rm -rf` the contents; the OS will regenerate on the next crash.

### AI tool debris

Coding assistants leave a lot of state behind. Most of it is recoverable from history; the rest is debug noise.

- **Claude Code:** `~/.claude/debug/`, `~/.claude/file-history/`, `~/.claude/telemetry/`. Also `~/.claude/projects/*/<session>.jsonl` files older than 28 days.
- **Cursor:** `~/Library/Application Support/Cursor/Cache` (macOS), `~/.config/Cursor/Cache` (Linux). Same for the `CachedData` subdir.
- **GitHub Copilot:** the LSP server caches under each editor's extension dir; usually small but worth a glance.

**NEVER touch** memories, settings, slash commands, skills, or conversation history:
- `~/.claude/memory/`, `~/.claude/projects/*/memory/`
- `~/.claude/commands/`, `~/.claude/skills/`
- `~/.claude/settings*.json`, `~/.claude/history.jsonl`

### App caches

- **macOS:** scan `~/Library/Caches/` for subdirectories larger than 50 MB. Report each with its parent app name. Common culprits: Slack, Discord, Spotify, JetBrains IDEs, Xcode (`~/Library/Developer/Xcode/DerivedData/` — easily multiple GB; nuke it without ceremony, Xcode rebuilds).
- **Linux:** scan `~/.cache/` for subdirectories larger than 50 MB.

For each large subdirectory, the clean command is `rm -rf <path>/*` (contents only — don't remove the directory the app expects to exist).

**Warn the user to close the app first.** Files held open will fail silently or, worse, corrupt the cache index.

### Browser caches

- Chrome: `~/Library/Application Support/Google/Chrome/Default/Cache` + `Code Cache` (macOS), `~/.config/google-chrome/Default/Cache` (Linux).
- Brave: same path, `BraveSoftware/Brave-Browser/` instead of `Google/Chrome/`.
- Firefox: `~/Library/Caches/Firefox/Profiles/<id>/cache2` (macOS), `~/.cache/mozilla/firefox/<id>/cache2` (Linux).
- Safari: `~/Library/Caches/com.apple.Safari/`.

`rm -rf <path>/*` for each. Tell the user to close the browser first (locked files just get skipped, but it's cleaner). Logged-in sessions are stored separately and are *not* affected.

### Electron app updater leftovers

Apps that ship via Electron auto-updaters keep old version directories or pending update downloads after they've been applied. Common patterns:

- `~/Library/Application Support/<App>/Code Cache/` and `GPUCache/`
- Squirrel-style `app-<version>/` directories under `~/Library/Application Support/<App>/` — keep only the newest.

This category needs case-by-case detection. Worth the effort: a single old Slack/Linear/Discord version can be 300-500 MB.

## Safety rules

These are the rules that turn "LLM with shell access" from terrifying into useful.

- **Never `rm -rf $HOME` or `rm -rf /`.** Obvious, but easy to construct accidentally by interpolating an empty variable. Always validate paths are non-empty and contain at least two segments before deleting.
- **Never auto-delete.** Every category gets shown in the report; nothing is removed until the user picks numbers.
- **Per-item confirmation for ambiguous categories.** If you're guessing at orphaned AppData/Library directories (i.e., trying to figure out if an app is uninstalled), show each candidate and let the user confirm. Don't bulk-delete.
- **Read `.gitignore` before deleting `dist/`, `build/`, `out/`.** If the project commits its build output, deleting it is destructive.
- **Skip locked files silently.** If a browser or app is running, you'll get permission errors. Log them, keep going.
- **Don't touch system update files** unless explicitly requested. Disk Cleanup / Storage Sense exists on every OS for that reason.
- **No `--no-preserve-root`, no `-rf /`, no operations on directories you didn't measure first.** If you can't `du` it, you don't `rm` it.

## Report format

Aim for a single readable table. The user is scanning visually:

```
Disk: 6.8 GB free / 120 GB total (94% used)

 #  Category                Items                                     Size
 1  npm cache               ~/.npm/_cacache                           5.3 GB
 2  node_modules (inactive) project-a, project-b, project-c (+12)     2.5 GB
 3  Xcode DerivedData       ~/Library/Developer/Xcode/DerivedData     1.8 GB
 4  Browser caches          Chrome (513), Firefox (945), Brave (607)  2.0 GB
 5  Docker reclaimable      images + build cache                      1.3 GB
 6  pip cache               ~/Library/Caches/pip                       234 MB
                                                              Total:  13.4 GB

Which categories to clean? (e.g., 1,2,3 / all / none)
```

A few rules for the table:

- Only include categories that found *something* — skip empty rows entirely.
- Sort by size descending.
- For "Items": up to 3 names, then `(+N more)`.
- Always show the disk free/total/% header — it's the most important context.
- Always show the total at the bottom.

## Optional: faster scanning

If `du -sh` is too slow on a nearly-full disk, alternatives:

- **macOS:** `mdfind -onlyin <path> -count 'kMDItemFSSize > 0'` for indexed paths.
- **Linux:** `ncdu --exclude-from <list>` for interactive, or `gdu` for parallel.
- **Windows:** WizTree reads the NTFS Master File Table directly — full drive scan in 10-30 seconds. If installed, export to CSV and use it as a lookup table for every category size; this turns a multi-minute scan into seconds.

These are nice-to-haves, not required. `du -sm` on the paths above is fast enough for most setups.

## Windows appendix

Most of the above works on Windows under Git Bash / WSL with path translation. A few categories are Windows-specific and worth checking on a Windows dev box:

- **`C:\hiberfil.sys`** — hibernation file, often 4-8 GB. Disable with `powercfg /h off` (elevated) if you never hibernate.
- **`C:\Windows\LiveKernelReports\`** — kernel watchdog dumps (single dumps can be 2-3 GB). Elevated `Remove-Item`.
- **`C:\Windows.old\`** — previous Windows installation after a major update. Use Settings → System → Storage → Temporary Files. Don't `rm -rf` — permission errors.
- **`%LOCALAPPDATA%\<app>\app-<version>\`** — Squirrel updater leaves old Electron app versions here. Keep only the newest `app-*` directory.
- **`C:\ProgramData\Microsoft\VisualStudio\Packages\`** — VS installer cache, often several GB. Elevated `Remove-Item`. VS will redownload packages if needed.
- **`C:\Program Files (x86)\Windows Kits\10\Lib\<version>\`** — old Windows SDK versions side-by-side. Keep the newest; the rest are usually unreferenced.
- **Orphaned VS installations** — directories under `Microsoft Visual Studio\<year>\` that `vswhere.exe -all` doesn't list anymore. Safe to remove.
- **Browser/Electron caches** — same as Unix, but under `%LOCALAPPDATA%\<App>\User Data\Default\Cache` (Chromium-family) or `%APPDATA%\<App>\Cache`.

Elevated operations should be batched: write all the `Remove-Item` calls to a single PowerShell script and launch it once with `Start-Process -Verb RunAs` so the user sees one UAC prompt, not ten.

## Why this exists

Disk cleanup is the perfect LLM task: tedious enough that nobody does it, but rule-based enough that a model with shell access can do it correctly if you tell it the rules. The hard part isn't deleting things — it's knowing what's safe, where to look, and how to surface it without making the user read 400 lines of `du` output.

The original full version of this skill lives at [zhiganov/agentic-cleanup](https://github.com/zhiganov/agentic-cleanup) — it includes Windows-first detection, WizTree integration, and more categories. This gist is the portable Karpathy-style version: copy the contents into your LLM, run it, get your disk back.
