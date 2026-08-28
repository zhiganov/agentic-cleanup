# Detect orphaned %APPDATA% / %LOCALAPPDATA% dirs (app uninstalled, data left behind).
# Output (stdout, parsed by the command): <dirName>|<sizeMB>|<fullPath>
# Pass -Explain to get per-directory keep/skip reasoning on stderr (stdout stays clean).
#
# 4-layer filter chain, ported from the Linux orphan scan (2026-07-16, issue #9).
# Before the port this script had ONE layer -- an exact-match skiplist plus a substring
# registry test -- and produced 6/6 false positives on a real run:
#
#   npm-cache 1058MB | pnpm 51MB | uv 71MB | node-gyp 61MB | RealtimeBoard 72MB | CrashDumps 106MB
#
# Every one was live or another category's target. The skiplist held 'npm' and 'node.js',
# but the test was `-eq`, so 'npm-cache' and 'node-gyp' sailed through. A category where
# every row is wrong is worse than no category: it trains the user to click through the
# per-item confirmation that is the only thing protecting them.
#
# Layers, cheapest first:
#   1. Allowlist        -- system dirs + dev-tool surface + anything another category owns
#   2. Active binary    -- Get-Command <dirname> resolves => live tool on PATH
#   3. Package match    -- registry DisplayName at a TOKEN BOUNDARY, never substring
#   4. Recent activity  -- any file modified in 30d => not abandoned (bails on first hit)
[CmdletBinding()]
param(
    [switch]$Explain,
    [int]$MinMB = 50,
    [int]$RecentDays = 30
)

function Say($msg) { if ($Explain) { [Console]::Error.WriteLine($msg) } }

# ---------------------------------------------------------------- installed set
$installed = @()
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
foreach ($rp in $regPaths) {
    Get-ItemProperty $rp -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DisplayName)     { $installed += $_.DisplayName.ToLower() }
        if ($_.InstallLocation) { $installed += (Split-Path $_.InstallLocation -Leaf).ToLower() }
    }
}
$installed = $installed | Where-Object { $_ } | Select-Object -Unique

# ------------------------------------------------------- layer 1: allowlist
# System / platform dirs that belong to no single uninstallable package.
$skipDirs = @(
    'microsoft', 'windows', '.net', 'identities', 'adobe', 'intel', 'nvidia',
    'apple', 'sun', 'java', 'oracle', 'nuget', 'python', 'pip', 'npm',
    'node.js', 'git', 'ssh', 'gnupg', 'local', 'locallow', 'roaming',
    'temp', 'temporary internet files', 'packages', 'connecteddevicesplatform',
    'publishers', 'comms', 'windowsapps', 'programs', 'microsoft\windows',
    'agentic-cleanup'
)

# Dev-tool surface. These are installed by curl|iwr scripts or bundled runtimes and
# never appear in the uninstall registry, so the package match can never vouch for them.
$devTools = @(
    'npm-cache', 'pnpm', 'pnpm-store', 'yarn', 'uv', 'uvtools', 'node-gyp', 'nvm',
    'nvs', 'bun', 'deno', 'cargo', 'rustup', 'go-build', 'gradle', 'maven', 'pipx',
    'poetry', 'pyenv', 'rbenv', 'composer', 'ms-playwright', 'puppeteer', 'electron',
    'esbuild', 'sccache', 'turbo', 'vite', 'nx', 'jetbrains', 'gh', 'hub'
)

# Dirs that are ANOTHER CATEGORY'S TARGET. Excluded here by construction so this scan
# can never offer them -- npm-cache is the sharpest: the _npx warning says it must never
# be whole-dir deleted, and the un-filtered orphan scan offered exactly that.
$categoryOwned = @(
    'npm-cache', 'crashdumps', 'temp', 'claude', 'cleanup-scripts', 'ms-playwright',
    'deliveryoptimization', 'livekernelreports', 'squirreltemp', 'packagecache'
)

$allow = @($skipDirs + $devTools + $categoryOwned) | ForEach-Object { $_.ToLower() } | Select-Object -Unique

# Dirs named for a former product/company, where a registry lookup by dir name cannot
# match. Best-effort and inherently incomplete -- layers 2/4 are the real safety net.
$aliases = @{
    'realtimeboard' = 'miro'
    'code - insiders' = 'visual studio code'
    'discordptb' = 'discord'
    'discordcanary' = 'discord'
}

# ------------------------------------------------------- layer 3: package match
# Decorated dir names don't match the registry as-is: '@lineardesktop-updater' and
# 'realtimeboard-updater' are Linear's and Miro's updater caches, and both apps are
# installed -- but the '@' prefix and '-updater' suffix defeat every name test, so the
# un-normalized scan reported them as orphans (2026-07-16, second round).
function Get-NameCandidates([string]$name) {
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add($name)
    $n = $name.TrimStart('@')
    if ($n -ne $name) { $out.Add($n) }
    foreach ($suf in @('-updater', '-helper', '-cache', '-shipit')) {
        if ($n.EndsWith($suf) -and $n.Length -gt $suf.Length) {
            $out.Add($n.Substring(0, $n.Length - $suf.Length).TrimEnd('-', '.', '_'))
        }
    }
    foreach ($x in @($out)) { if ($aliases.ContainsKey($x)) { $out.Add($aliases[$x]) } }
    return ($out | Select-Object -Unique)
}

function Test-PackageMatch([string]$name) {
    foreach ($c in Get-NameCandidates $name) {
        $re = "(^|[\s\-\._])" + [regex]::Escape($c) + "($|[\s\-\._])"
        foreach ($p in $installed) {
            # token boundary, NOT substring -- 'zen' must not be swallowed by 'zenity'.
            if ($p -eq $c -or $p -match $re) { return "'$c' in '$p'" }

            # Liberal prefix rule. Windows DisplayNames append the version ("Linear 1.29.5",
            # "Miro 0.8.61"), so the first token IS the app name -- unlike Linux, where the
            # doc rightly warns first-token matching is overly broad. Skip when the dir name
            # STARTS WITH an installed app's first token ('lineardesktop' -> 'linear').
            #
            # Direction matters: this is dir.StartsWith(pkg), not pkg.Contains(dir), so the
            # Linux 'zenity' swallowing 'zen' case cannot happen here.
            #
            # Deliberately biased toward skipping. In THIS category the errors are not
            # symmetric: a false positive offers live data for deletion and trains the user
            # to click through the per-item confirmation that is their only protection; a
            # false negative just leaves some disk unreclaimed. When unsure, skip.
            $tok = $p.Split(' ')[0]
            if ($tok.Length -ge 4 -and $c.StartsWith($tok)) { return "'$c' starts with '$tok' ('$p')" }
        }
    }
    return $null
}

# ------------------------------------------------------- layer 4: recent activity
function Test-RecentActivity([string]$path, [int]$days) {
    $cutoff = (Get-Date).AddDays(-$days)
    # Select-Object -First 1 stops the upstream enumeration -- bails on first hit,
    # does not walk the whole tree.
    $hit = Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -gt $cutoff } |
           Select-Object -First 1
    return $hit
}

# ---------------------------------------------------------------- scan
foreach ($loc in @($env:APPDATA, $env:LOCALAPPDATA)) {
    if (-not $loc -or -not (Test-Path $loc)) { continue }
    Get-ChildItem $loc -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_
        $name = $dir.Name.ToLower()

        if ($name.StartsWith('.')) { Say "skip  $($dir.Name): dotdir"; return }

        # layer 1
        if ($allow -contains $name) { Say "skip  $($dir.Name): allowlist"; return }

        # layer 2
        $cmd = Get-Command $dir.Name -ErrorAction SilentlyContinue
        if ($cmd) { Say "skip  $($dir.Name): active binary ($($cmd.Source))"; return }

        # layer 3
        $match = Test-PackageMatch $name
        if ($match) { Say "skip  $($dir.Name): installed (matched '$match')"; return }

        # layer 4
        $recent = Test-RecentActivity $dir.FullName $RecentDays
        if ($recent) {
            Say "skip  $($dir.Name): modified $($recent.LastWriteTime.ToString('yyyy-MM-dd')) (<${RecentDays}d)"
            return
        }

        $s = (Get-ChildItem $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
        $mb = [math]::Round($s / 1MB)
        if ($mb -gt $MinMB) {
            Say "ORPHAN $($dir.Name): ${mb}MB, no activity in ${RecentDays}d"
            Write-Output "$($dir.Name)|$mb|$($dir.FullName)"
        } else {
            Say "skip  $($dir.Name): ${mb}MB < ${MinMB}MB"
        }
    }
}
