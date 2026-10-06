[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ScanLogs', 'CleanLogs', 'Analyze', 'Components')][string]$Action,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$EvidencePath,
    [int]$MaximumWaitSeconds = 30,
    [switch]$Approved,
    [switch]$WhatIf
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_maintenance.ps1')
$contractRoot = Join-Path $PSScriptRoot '..\..\cleanup'
Import-Module (Join-Path $contractRoot 'Cleanup.Contracts.psm1') -Force
if (Test-Path -LiteralPath $OutputPath) { throw 'Worker output already exists; use a new task-owned path' }
$roots = @((Join-Path $env:SystemRoot 'Logs\CBS'), (Join-Path $env:ProgramData 'Comms\PCManager\log'))
$result = [ordered]@{ schemaVersion = '1.0'; action = $Action; status = 'incomplete'; reason = 'not-started'
    startedAt = [DateTime]::UtcNow.ToString('o'); completedAt = $null; analysis = $null; operations = @()
    nativeExitCode = $null; diskBefore = $null; diskAfter = $null }
function Invoke-Analysis {
    $text = @(& "$env:SystemRoot\System32\dism.exe" /Online /English /Cleanup-Image /AnalyzeComponentStore /NoRestart 2>&1)
    $code = $LASTEXITCODE
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $context = "$($os.LastBootUpTime.ToUniversalTime().ToString('o'))|$($os.Version)|$($os.BuildNumber)"
    ConvertFrom-CleanupDismAnalysis -Text ($text -join "`n") -ExitCode $code -Context $context
}
try {
    if ($Action -eq 'ScanLogs') {
        $result.analysis = Get-CleanupLogEvidence -Roots $roots
        $result.status = 'complete'; $result.reason = 'read-only'
    } else {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $result.status = 'manual-required'; $result.reason = 'already-elevated-trusted-worker-required'
        } elseif ($Action -in @('Components', 'CleanLogs') -and -not $Approved -and -not $WhatIf) {
            $result.status = 'blocked'; $result.reason = 'explicit-selection-required'
        } else {
            $guard = Wait-CleanupServicingIdle -MaximumSeconds $MaximumWaitSeconds
            if (-not $guard.ready) { $result.status = 'blocked'; $result.reason = $guard.reason }
            elseif ($Action -eq 'Analyze') {
                $result.analysis = Invoke-Analysis
                $result.status = $result.analysis.status; $result.reason = 'analysis-only'
                $result.nativeExitCode = $result.analysis.nativeExitCode
            } elseif ($Action -eq 'CleanLogs') {
                if (-not $EvidencePath) { throw 'Selected log evidence is required' }
                $document = [IO.File]::ReadAllText($EvidencePath) | ConvertFrom-Json -Depth 20
                $live = @(& (Join-Path $PSScriptRoot 'live_paths.ps1'))
                $result.diskBefore = [long](Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
                $result.operations = @(Invoke-CleanupSelectedLogs -Evidence $document.analysis -AllowedRoots $roots -LivePaths $live -WhatIf:$WhatIf)
                $result.status = if (@($result.operations | Where-Object status -in @('failed', 'partial')).Count) { 'incomplete' } else { 'complete' }
                $result.reason = 'exact-selected-files-only'
                $result.diskAfter = [long](Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
            } else {
                if ($EvidencePath) {
                    $document = [IO.File]::ReadAllText($EvidencePath) | ConvertFrom-Json -Depth 20
                    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                    $context = "$($os.LastBootUpTime.ToUniversalTime().ToString('o'))|$($os.Version)|$($os.BuildNumber)"
                    if (Test-CleanupAnalysisFresh $document.analysis -Context $context) { $result.analysis = $document.analysis }
                }
                if ($null -eq $result.analysis) { $result.analysis = Invoke-Analysis }
                # AnalyzeComponentStore may leave a servicing worker running.
                # Wait for its natural exit; never stop it or weaken the guard.
                $guard = Wait-CleanupServicingIdle -MaximumSeconds $MaximumWaitSeconds
                if ($result.analysis.status -ne 'complete') { $result.status = 'incomplete'; $result.reason = 'analysis-incomplete' }
                elseif (-not $guard.ready) { $result.status = 'blocked'; $result.reason = $guard.reason }
                elseif (-not $result.analysis.cleanupRecommended -or $result.analysis.reclaimablePackages -eq 0 -or $WhatIf) {
                    $result.status = 'complete'; $result.reason = 'validated-noop'
                } else {
                    $result.diskBefore = [long](Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
                    $nativeOutput = @(& "$env:SystemRoot\System32\dism.exe" /Online /English /Cleanup-Image /StartComponentCleanup /NoRestart 2>&1)
                    $result.nativeExitCode = $LASTEXITCODE
                    $result.diskAfter = [long](Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
                    $result.status = if ($result.nativeExitCode -eq 0) { 'complete' } else { 'incomplete' }
                    $result.reason = 'single-supported-pass-no-resetbase-no-reboot'
                    $postGuard = Wait-CleanupServicingIdle -MaximumSeconds $MaximumWaitSeconds
                    if ($postGuard.ready) {
                        $result.analysis = Invoke-Analysis
                        if ($result.analysis.status -ne 'complete') { $result.status = 'incomplete'; $result.reason = 'cleanup-finished-post-analysis-incomplete' }
                    }
                    else { $result.reason = 'cleanup-finished-post-analysis-blocked'; $result.status = 'incomplete' }
                }
            }
        }
    }
} catch { $result.status = 'incomplete'; $result.reason = 'worker-operation-failed' }
$result.completedAt = [DateTime]::UtcNow.ToString('o')
Write-ImmutableJson $result ([IO.Path]::GetFullPath($OutputPath))
# Native output, registry data, command lines and exception messages stay private.
[ordered]@{ status = $result.status; reason = $result.reason; action = $Action } | ConvertTo-Json -Compress
if ($result.status -eq 'incomplete') { exit 1 }
