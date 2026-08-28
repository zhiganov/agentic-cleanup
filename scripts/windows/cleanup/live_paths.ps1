# Emit filesystem paths that RUNNING processes depend on, so a delete candidate can be
# vetoed on liveness rather than on a proxy for liveness.
#
#   stdout          : one live path per line (feed to assert_list.py --live)
#   stderr, -Summary: runtime process count + MCP servers per process
#   stdout, -JsonSummary: structured Claude Code/OpenCode census only
#
# Why (2026-07-16). Git inactivity, registry absence and "no lockfile" are proxies for
# "dead", and they are wrong often enough to destroy things. One /cleanup run produced
# five near-misses and FOUR were caught by a file lock rather than by judgement:
#
#   npm-cache      %LOCALAPPDATA%\npm-cache\_npx\ is where npx -y materialises packages,
#                  so live MCP servers execute from inside it -- one set per session.
#   %TEMP%\claude  Claude Code's own scratch; deleting it killed a Bash call mid-flight.
#   .next          another session's build, 11 minutes old, 1250/1279 files fresh.
#   node_modules   two book-power dirs flagged INACTIVE by git while backing live MCPs.
#
# A path appearing in a running process's command line is live REGARDLESS of what git,
# the registry, or a config file says. That is the only signal that is not a proxy.
#
# Parallel sessions make this sharper, not softer: two sessions were live when the run
# above happened, 12 MCP servers each. Assume another session exists.
[CmdletBinding()]
param(
    [switch]$Summary,
    [switch]$JsonSummary,
    [string]$ProcessFixture
)

$ErrorActionPreference = 'Stop'

$procs = @{}
$processFailure = $null
try {
    $processRows = if ($ProcessFixture) {
        @(Get-Content -LiteralPath $ProcessFixture -Raw | ConvertFrom-Json)
    } else {
        @(Get-CimInstance Win32_Process -ErrorAction Stop)
    }
} catch {
    $processRows = @()
    $processFailure = $_.Exception.Message
}
$processRows | ForEach-Object {
    $procs[[int]$_.ProcessId] = $_
}

# --resume takes a UUID *or* a quoted session name ("Avails - standing availability epic").
# A bare \S+ capture silently truncates the name at the first space and keeps the opening
# quote -- fine for grouping, wrong for display. Match the quoted form first.
function Get-ResumeId($cmdline) {
    if ($cmdline -match '--resume\s+"([^"]*)"') { return $Matches[1] }
    if ($cmdline -match '--resume\s+(\S+)')     { return $Matches[1] }
    return '(no --resume id)'
}

function Get-OwningSession([int]$id) {
    $seen = @{}; $c = $id
    while ($c -and $procs.ContainsKey($c) -and -not $seen[$c]) {
        $seen[$c] = $true
        $p = $procs[$c]
        if ($p.Name -eq 'claude.exe') { return (Get-ResumeId $p.CommandLine) }
        $c = [int]$p.ParentProcessId
    }
    return $null
}

function Test-DescendantOf([int]$id, [int]$ancestorId) {
    $seen = @{}; $c = $id
    while ($c -and $procs.ContainsKey($c) -and -not $seen[$c]) {
        if ($c -eq $ancestorId) { return $true }
        $seen[$c] = $true
        $c = [int]$procs[$c].ParentProcessId
    }
    return $false
}

$census = [System.Collections.Generic.List[object]]::new()
$limitations = [System.Collections.Generic.List[string]]::new()
if ($processFailure) {
    $limitations.Add("Process enumeration failed: $processFailure")
}
$claudeSessions = @($procs.Values | Where-Object { $_.Name -eq 'claude.exe' })
foreach ($session in $claudeSessions) {
    $id = Get-ResumeId $session.CommandLine
    $mcp = @($procs.Values | Where-Object {
        $_.Name -eq 'node.exe' -and $_.CommandLine -match '_npx|mcp' -and
        (Get-OwningSession([int]$_.ProcessId)) -eq $id
    }).Count
    $census.Add([ordered]@{
        runtime = 'claude-code'
        pid = [int]$session.ProcessId
        sessionId = if ($id -eq '(no --resume id)') { $null } else { $id }
        serverCount = $mcp
    })
}

$openCodeProcesses = @($procs.Values | Where-Object { $_.Name -eq 'opencode2.exe' })
foreach ($process in $openCodeProcesses) {
    $isService = $process.CommandLine -match '\bserve\s+--service\b'
    $servers = if ($isService) {
        @($procs.Values | Where-Object {
            $_.Name -eq 'node.exe' -and $_.CommandLine -match '_npx|mcp' -and
            (Test-DescendantOf ([int]$_.ProcessId) ([int]$process.ProcessId))
        }).Count
    } else { 0 }
    $census.Add([ordered]@{
        runtime = 'opencode'
        pid = [int]$process.ProcessId
        sessionId = $null
        serverCount = $servers
    })
}
if ($openCodeProcesses.Count -gt 0) {
    $limitations.Add('OpenCode process ancestry is shared-service evidence and cannot attribute a process to an exact session.')
}

if ($JsonSummary) {
    [ordered]@{
        status = if ($processFailure) { 'failed' } else { 'complete' }
        capturedAt = [DateTime]::UtcNow.ToString('o')
        sessions = @($census)
        limitations = @($limitations)
    } | ConvertTo-Json -Depth 6
    return
}

if ($processFailure) { throw "Process enumeration failed: $processFailure" }

if ($Summary) {
    [Console]::Error.WriteLine("runtime processes live: $($census.Count)")
    foreach ($entry in $census) {
        $session = if ($entry.sessionId) { $entry.sessionId } else { '(unavailable)' }
        [Console]::Error.WriteLine("  runtime=$($entry.runtime)  pid=$($entry.pid)  mcp_servers=$($entry.serverCount)  session=$session")
    }
    if ($census.Count -gt 1) {
        [Console]::Error.WriteLine("  NOTE: more than one runtime process is live; treat shared caches, scratch,")
        [Console]::Error.WriteLine("        and recently written build artifacts as potentially active.")
    }
    foreach ($limitation in $limitations) {
        [Console]::Error.WriteLine("  LIMITATION: $limitation")
    }
}

# Windows paths out of every command line: quoted (may contain spaces) and bare.
$out = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $procs.Values) {
    if ($p.ExecutablePath) { [void]$out.Add($p.ExecutablePath) }
    if (-not $p.CommandLine) { continue }
    foreach ($m in [regex]::Matches($p.CommandLine, '"([A-Za-z]:\\[^"]+)"')) {
        [void]$out.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($p.CommandLine, '(?<![":\w])([A-Za-z]:[\\/][^"''\s]+)')) {
        [void]$out.Add($m.Groups[1].Value)
    }
}
# Normalise forward slashes -- node is routinely launched with C:/Users/... style args.
$out | ForEach-Object { $_ -replace '/', '\' } |
    Sort-Object -Unique |
    ForEach-Object { Write-Output $_ }
