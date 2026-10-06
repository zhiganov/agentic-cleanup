# Dot-source library. No process launch or filesystem mutation at import time.
function Test-CleanupPlainPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { return $false }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $true
}

function Get-CleanupLogEvidence {
    param([Parameter(Mandatory)][string[]]$Roots, [int]$MinimumAgeDays = 7,
          [DateTime]$Now = [DateTime]::UtcNow, [switch]$TopDirectoryOnly)
    if ($MinimumAgeDays -lt 1) { throw 'Log age must be positive' }
    $selected = [Collections.Generic.List[object]]::new()
    $coverage = [Collections.Generic.List[object]]::new()
    foreach ($root in $Roots) {
        $isCbs = (Split-Path -Leaf $root) -ieq 'CBS'
        if (-not (Test-Path -LiteralPath $root)) { $coverage.Add(@{ root = $root; status = 'absent' }); continue }
        if (-not (Test-CleanupPlainPath $root)) { $coverage.Add(@{ root = $root; status = 'linked-skipped' }); continue }
        $pending = [Collections.Generic.Queue[string]]::new()
        $pending.Enqueue([IO.Path]::GetFullPath($root))
        $count = 0
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $status = 'complete'
        while ($pending.Count) {
            if ($timer.Elapsed.TotalSeconds -gt 30 -or $count -gt 50000) { $status = 'budget-exceeded'; break }
            $directory = $pending.Dequeue()
            if (-not (Test-CleanupPlainPath $directory)) { $status = 'partial'; continue }
            try { $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
            catch { $status = 'partial'; continue }
            $count += $children.Count
            $files = @($children | Where-Object { -not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
            $newest = @($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
            $newestLog = @($files | Where-Object Extension -in @('.log', '.txt') | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
            foreach ($file in $files) {
                if ($file.Name -ieq 'CBS.log' -or $file.Name -ieq 'DISM.log') { continue }
                $rotated = if ($isCbs) { $file.Name -match '^CbsPersist_[\w.-]+\.(log|cab)$' }
                           else { $file.Extension -in @('.log', '.txt', '.zip', '.cab') }
                if (-not $rotated -or $file.LastWriteTimeUtc -gt $Now.AddDays(-$MinimumAgeDays)) { continue }
                if (-not $isCbs -and $newest.Count -and $file.FullName -eq $newest[0].FullName) { continue }
                if (-not $isCbs -and $newestLog.Count -and $file.FullName -eq $newestLog[0].FullName) { continue }
                $selected.Add([ordered]@{ path = $file.FullName; logicalBytes = [long]$file.Length
                    modifiedAt = $file.LastWriteTimeUtc.ToString('o'); createdAt = $file.CreationTimeUtc.ToString('o') })
            }
            foreach ($child in $children | Where-Object PSIsContainer) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $status = 'partial'; continue }
                if (-not $isCbs -and -not $TopDirectoryOnly) { $pending.Enqueue($child.FullName) }
            }
        }
        $coverage.Add(@{ root = $root; status = $status })
    }
    [ordered]@{ schemaVersion = '1.0'; policyId = 'windows-rotated-logs'; capturedAt = $Now.ToString('o')
        minimumAgeDays = $MinimumAgeDays; roots = @($Roots); coverage = @($coverage); files = @($selected) }
}

function Invoke-CleanupSelectedLogs {
    param([Parameter(Mandatory)][object]$Evidence, [Parameter(Mandatory)][string[]]$AllowedRoots,
          [string[]]$LivePaths = @(), [switch]$WhatIf)
    if ($Evidence.policyId -ne 'windows-rotated-logs' -or $Evidence.schemaVersion -ne '1.0' -or
        @($Evidence.files).Count -eq 0 -or $Evidence.minimumAgeDays -lt 1) { throw 'Empty or malformed selected log evidence' }
    $captured = ([DateTimeOffset]$Evidence.capturedAt).UtcDateTime
    if ($captured -lt [DateTime]::UtcNow.AddHours(-1) -or
        $captured -gt [DateTime]::UtcNow.AddMinutes(1)) { throw 'Selected log evidence is stale' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $Evidence.files) {
        if (-not [IO.Path]::IsPathFullyQualified($record.path) -or -not $seen.Add($record.path)) { throw 'Invalid or duplicate selected log path' }
        $path = [IO.Path]::GetFullPath($record.path)
        $roots = @($AllowedRoots | Where-Object { $path.StartsWith([IO.Path]::GetFullPath($_).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($roots.Count -ne 1 -or $path -ne $record.path) { throw 'Selected log is outside its allowed root' }
    }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($record in $Evidence.files) {
        $status = 'failed'
        $reason = 'metadata-unavailable'
        $path = $record.path
        try {
            if (-not (Test-Path -LiteralPath $path)) { $status = 'validated-noop'; $reason = 'absent' }
            elseif (-not (Test-CleanupPlainPath $path)) { $status = 'skipped'; $reason = 'linked' }
            elseif (@($LivePaths | Where-Object { $_ -ieq $path }).Count) { $status = 'skipped'; $reason = 'live' }
            else {
                # Re-select from fresh directory metadata: protects newest PC
                # Manager log even if the prior newest file disappeared.
                $fresh = Get-CleanupLogEvidence -Roots @((Split-Path -Parent $path)) -MinimumAgeDays $Evidence.minimumAgeDays -TopDirectoryOnly
                $eligible = @($fresh.files | Where-Object path -eq $path)
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($eligible.Count -ne 1 -or $item.PSIsContainer -or $item.Length -ne $record.logicalBytes -or
                    $item.LastWriteTimeUtc.ToString('o') -ne $record.modifiedAt -or $item.CreationTimeUtc.ToString('o') -ne $record.createdAt) {
                    $status = 'skipped'; $reason = 'changed-current-or-fresh'
                } elseif ($WhatIf) { $status = 'validated-noop'; $reason = 'what-if' }
                else {
                    # Deny readers/writers; allow only delete-sharing. Keep the
                    # guard open through deletion, so locks never trigger retries.
                    $guard = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Delete)
                    try {
                        $current = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                        if ($current.Length -ne $record.logicalBytes -or $current.LastWriteTimeUtc.ToString('o') -ne $record.modifiedAt -or
                            $current.CreationTimeUtc.ToString('o') -ne $record.createdAt -or -not (Test-CleanupPlainPath $path)) {
                            $status = 'skipped'; $reason = 'changed'
                        } else {
                            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                            $status = if (Test-Path -LiteralPath $path) { 'partial' } else { 'removed' }
                            $reason = 'exact-selected-file'
                        }
                    } finally { $guard.Dispose() }
                }
            }
        } catch [IO.IOException] { $status = 'locked-skipped'; $reason = 'locked-or-io-error' }
        catch { $status = 'failed'; $reason = 'access-or-metadata-error' }
        $rows.Add([ordered]@{ path = $path; status = $status; reason = $reason
            logicalBytesRemoved = if ($status -eq 'removed') { [long]$record.logicalBytes } else { 0L } })
    }
    return @($rows)
}

function Get-CleanupServicingState {
    $names = @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object Name)
    $workers = @($names | Where-Object { $_ -in @('msiexec.exe', 'TiWorker.exe', 'TrustedInstaller.exe', 'MoUsoCoreWorker.exe', 'dism.exe', 'DismHost.exe') })
    $pending = $false
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending')) {
        if (Test-Path -LiteralPath $key) { $pending = $true }
    }
    $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    $renameProperty = $session.PSObject.Properties['PendingFileRenameOperations']
    if ($renameProperty -and @($renameProperty.Value).Count) { $pending = $true }
    [ordered]@{ complete = $true; pendingReboot = $pending; workerCount = $workers.Count
        capturedAt = [DateTime]::UtcNow.ToString('o') }
}

function Wait-CleanupServicingIdle {
    param([int]$MaximumSeconds = 30, [scriptblock]$Probe = { Get-CleanupServicingState },
          [scriptblock]$Delay = { param($seconds) Start-Sleep -Seconds $seconds })
    if ($MaximumSeconds -lt 0 -or $MaximumSeconds -gt 120) { throw 'Servicing wait must be bounded to 0..120 seconds' }
    $deadline = [DateTime]::UtcNow.AddSeconds($MaximumSeconds)
    do {
        $state = & $Probe
        if (-not $state.complete -or $state.pendingReboot) { return @{ ready = $false; reason = 'pending-or-unknown'; state = $state } }
        if ($state.workerCount -eq 0) { return @{ ready = $true; reason = 'idle'; state = $state } }
        if ([DateTime]::UtcNow -ge $deadline) { return @{ ready = $false; reason = 'worker-wait-expired'; state = $state } }
        & $Delay 1
    } while ($true)
}

function ConvertFrom-CleanupDismAnalysis {
    param([string]$Text, [int]$ExitCode, [string]$Context = '')
    $packages = $null
    $recommended = $null
    if ($Text -match 'Number of Reclaimable Packages\s*:\s*(\d+)') { $packages = [int]$Matches[1] }
    if ($Text -match 'Component Store Cleanup Recommended\s*:\s*(Yes|No)') { $recommended = $Matches[1] -eq 'Yes' }
    [ordered]@{ status = if ($ExitCode -eq 0 -and $null -ne $packages -and $null -ne $recommended) { 'complete' } else { 'incomplete' }
        nativeExitCode = $ExitCode; reclaimablePackages = $packages; cleanupRecommended = $recommended
        estimatedReclaimableBytes = $null; capturedAt = [DateTime]::UtcNow.ToString('o'); machine = [Environment]::MachineName; context = $Context }
}

function Test-CleanupAnalysisFresh {
    param([object]$Analysis, [string]$Machine = [Environment]::MachineName, [DateTime]$Now = [DateTime]::UtcNow, [string]$Context = '')
    try {
        $captured = ([DateTimeOffset]$Analysis.capturedAt).UtcDateTime
        # Preserve the integer/boolean contract across in-memory and JSON forms.
        if ($Analysis.cleanupRecommended -isnot [bool] -or
            ($Analysis.reclaimablePackages -isnot [int] -and $Analysis.reclaimablePackages -isnot [long]) -or
            $Analysis.reclaimablePackages -lt 0) { return $false }
        $Analysis.status -eq 'complete' -and $Analysis.nativeExitCode -eq 0 -and $Analysis.machine -eq $Machine -and
            $Analysis.context -eq $Context -and
            $captured -le $Now.AddMinutes(1) -and $captured -ge $Now.AddMinutes(-15)
    } catch { return $false }
}

function Get-CleanupWorkerOutcome {
    param([string]$LaunchStatus, $WorkerExitCode, [object]$Result)
    if ($LaunchStatus -eq 'uac-declined') { return 'uac-declined' }
    if ($LaunchStatus -ne 'started') { return 'launch-failed' }
    if ($null -eq $WorkerExitCode) { return 'pending' }
    if ($null -eq $Result) { return 'missing-result' }
    if ($WorkerExitCode -ne 0 -or $Result.status -ne 'complete') { return 'incomplete' }
    return 'complete'
}
