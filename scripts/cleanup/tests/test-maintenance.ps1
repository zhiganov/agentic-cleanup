$ErrorActionPreference = 'Stop'
$helpers = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'windows\cleanup'
. (Join-Path $helpers 'windows_maintenance.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('cleanup-maintenance-test-' + [guid]::NewGuid())
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}
function Add-Log([string]$Path, [int]$Days) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, 'synthetic diagnostic')
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-$Days)
}
try {
    $cbs = Join-Path $root 'CBS'
    $oem = Join-Path $root 'PCManager\log'
    Add-Log (Join-Path $cbs 'CBS.log') 30
    Add-Log (Join-Path $cbs 'CbsPersist_old.log') 30
    Add-Log (Join-Path $cbs 'CbsPersist_locked.log') 30
    Add-Log (Join-Path $cbs 'CbsPersist_changed.log') 30
    Add-Log (Join-Path $cbs 'CbsPersist_live.log') 30
    Add-Log (Join-Path $cbs 'CbsPersist_fresh.log') 1
    Add-Log (Join-Path $oem 'newest.log') 8
    Add-Log (Join-Path $oem 'newer-archive.zip') 7
    Add-Log (Join-Path $oem 'older.log') 30
    Add-Log (Join-Path $oem 'sub\newest.log') 8
    Add-Log (Join-Path $oem 'sub\older.log') 30
    $evidence = Get-CleanupLogEvidence -Roots @($cbs, $oem)
    Assert-True (@($evidence.files).Count -eq 6) 'Discovery selects only old rotated files, preserving newest logs per directory'
    (Get-Item -LiteralPath (Join-Path $cbs 'CbsPersist_changed.log')).LastWriteTimeUtc = [DateTime]::UtcNow
    $locked = [IO.File]::Open((Join-Path $cbs 'CbsPersist_locked.log'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $rows = @(Invoke-CleanupSelectedLogs -Evidence $evidence -AllowedRoots @($cbs, $oem) -LivePaths @((Join-Path $cbs 'CbsPersist_live.log'))) }
    finally { $locked.Dispose() }
    Assert-True (@($rows | Where-Object status -eq 'removed').Count -eq 3) 'Only exact selected and unchanged unlocked files are removed'
    Assert-True (@($rows | Where-Object status -eq 'locked-skipped').Count -eq 1) 'Locked file is preserved without retries'
    Assert-True (@($rows | Where-Object status -eq 'skipped').Count -eq 2) 'Changed and live files are preserved'
    Assert-True ((Test-Path $cbs) -and (Test-Path $oem) -and (Test-Path (Join-Path $cbs 'CBS.log')) -and (Test-Path (Join-Path $oem 'newest.log'))) 'Current logs and roots survive'
    $linkedRoot = Join-Path $root 'linked-logs'
    New-Item -ItemType Junction -Path $linkedRoot -Target $oem | Out-Null
    $linked = Get-CleanupLogEvidence -Roots @($linkedRoot)
    Assert-True ($linked.coverage[0].status -eq 'linked-skipped' -and @($linked.files).Count -eq 0) 'Linked log roots are not traversed or selected'
    & cmd.exe /d /c rmdir "$linkedRoot"
    if ($LASTEXITCODE) { throw 'Cannot remove synthetic log junction' }
    $empty = @{ schemaVersion = '1.0'; policyId = 'windows-rotated-logs'; files = @(); minimumAgeDays = 7 }
    $failed = $false
    try { Invoke-CleanupSelectedLogs -Evidence $empty -AllowedRoots @($cbs, $oem) } catch { $failed = $true }
    Assert-True $failed 'Malformed/empty selected evidence fails closed'

    $analysis = ConvertFrom-CleanupDismAnalysis 'Number of Reclaimable Packages : 2
Component Store Cleanup Recommended : Yes' 0
    Assert-True ($analysis.status -eq 'complete' -and $analysis.reclaimablePackages -eq 2 -and $null -eq $analysis.estimatedReclaimableBytes) 'Successful DISM with remaining packages is not a recovery estimate'
    Assert-True (Test-CleanupAnalysisFresh $analysis) 'Recent same-machine analysis is reusable'
    $malformed = $analysis | ConvertTo-Json | ConvertFrom-Json
    $malformed.cleanupRecommended = 'Yes'
    Assert-True (-not (Test-CleanupAnalysisFresh $malformed)) 'Malformed reused analysis does not coerce string flags into approval'
    Assert-True (-not (Test-CleanupAnalysisFresh $analysis -Context 'different-boot')) 'A reboot or operating-system context change invalidates reused analysis'
    $analysis.capturedAt = [DateTime]::UtcNow.AddHours(-1).ToString('o')
    Assert-True (-not (Test-CleanupAnalysisFresh $analysis)) 'Stale analysis requires reanalysis'
    Assert-True ((ConvertFrom-CleanupDismAnalysis '' 0).status -eq 'incomplete') 'Native zero with missing analysis fields is incomplete'
    Assert-True ((Get-CleanupWorkerOutcome 'uac-declined' $null $null) -eq 'uac-declined') 'Observed UAC decline is distinct from missing output'
    Assert-True ((Get-CleanupWorkerOutcome 'started' 0 $null) -eq 'missing-result') 'Missing result is not UAC decline'
    Assert-True ((Get-CleanupWorkerOutcome 'started' 0 @{ status = 'incomplete' }) -eq 'incomplete') 'Worker-zero/incomplete-result is not success'
    Assert-True ((Get-CleanupWorkerOutcome 'started' $null $null) -eq 'pending') 'Pending worker cannot be reported complete'
    $pending = Wait-CleanupServicingIdle -MaximumSeconds 0 -Probe { @{ complete = $true; pendingReboot = $true; workerCount = 0 } }
    Assert-True (-not $pending.ready) 'Pending reboot blocks mutation'
    $worker = Wait-CleanupServicingIdle -MaximumSeconds 0 -Probe { @{ complete = $true; pendingReboot = $false; workerCount = 1 } }
    Assert-True ($worker.reason -eq 'worker-wait-expired') 'Active/lingering installer is preserved at bounded wait expiry'
    $script:probes = 0
    $natural = Wait-CleanupServicingIdle -MaximumSeconds 1 -Probe {
        $script:probes++
        @{ complete = $true; pendingReboot = $false; workerCount = $(if ($script:probes -eq 1) { 1 } else { 0 }) }
    } -Delay { param($seconds) }
    Assert-True $natural.ready 'Lingering worker may exit naturally without bypass or process stop'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $root) { throw 'Fixture cleanup incomplete' }
}
Write-Output 'All focused maintenance fixtures passed.'
