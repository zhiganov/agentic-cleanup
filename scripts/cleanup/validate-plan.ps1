[CmdletBinding()]
param(
    [string]$ScanPath,
    [string]$PlanPath,
    [object]$ScanObject,
    [object]$PlanObject,
    [string]$ScanDigest,
    [string[]]$OperationId,
    [string]$PolicyRegistryPath = (Join-Path $PSScriptRoot 'policies\windows.v1.json'),
    [string]$HelpersDirectory = (Join-Path $PSScriptRoot '..\windows\cleanup'),
    [string]$ProcessFixture,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cleanup.Contracts.psm1') -Force
$scanSchema = Join-Path $PSScriptRoot 'schemas\scan.schema.json'
$planSchema = Join-Path $PSScriptRoot 'schemas\plan.schema.json'

function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }

function Test-PathInside([string]$Path, [string]$Root) {
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-NewestWrite([string]$Path) {
    $latest = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object LastWriteTimeUtc -Maximum).Maximum
    if ($null -eq $latest) { return (Get-Item -LiteralPath $Path).LastWriteTimeUtc }
    [DateTime]$latest
}

function Test-RootPolicy([object]$Operation, [object]$Scan, [object]$Registry, [bool]$FixtureMode) {
    $registration = @($Registry.rootPolicies | Where-Object rootPolicyId -eq $Operation.preconditions.rootPolicyId)[0]
    $path = [string]$Operation.target.canonicalPath
    switch ($registration.pathClass) {
        'npm-cacache' {
            if (-not $FixtureMode) {
                if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return $false }
                $configured = (& npm config get cache 2>$null | Select-Object -First 1)
                if (-not $configured -or -not [IO.Path]::IsPathFullyQualified([string]$configured)) { return $false }
                return $path -eq [IO.Path]::GetFullPath((Join-Path ([string]$configured) '_cacache'))
            }
            return (Split-Path -Leaf $path) -eq '_cacache' -and (Split-Path -Leaf (Split-Path -Parent $path)) -eq 'npm-cache'
        }
        'user-temp' {
            if (-not $FixtureMode) { return $path -eq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') }
            $resource = @($Scan.categories.items.resources | Where-Object resourceId -eq 'user-temp-root')[0]
            return $path -eq $resource.canonicalPath
        }
        'workspace-build-artifact' {
            return (Test-PathInside $path $Scan.workspace.root) -and (Split-Path -Leaf $path) -in @('.next', '.turbo', '.parcel-cache', '.vite')
        }
        'config-msi' {
            if (-not $FixtureMode) { return $path -eq [IO.Path]::GetFullPath("$env:SystemDrive\Config.Msi") }
            return (Split-Path -Leaf $path) -eq 'Config.Msi'
        }
        'windows-old' {
            if (-not $FixtureMode) { return $path -eq [IO.Path]::GetFullPath("$env:SystemDrive\Windows.old") }
            return (Split-Path -Leaf $path) -eq 'Windows.old'
        }
        default { return $false }
    }
}

$scanFile = if ($ScanPath) { [IO.Path]::GetFullPath($ScanPath) } else { $null }
$planFile = if ($PlanPath) { [IO.Path]::GetFullPath($PlanPath) } else { $null }
$scan = if ($null -ne $ScanObject) { $ScanObject } elseif ($scanFile) { Read-Json $scanFile } else { throw 'ScanPath or ScanObject is required' }
$plan = if ($null -ne $PlanObject) { $PlanObject } elseif ($planFile) { Read-Json $planFile } else { throw 'PlanPath or PlanObject is required' }
$resolvedScanDigest = if ($ScanDigest) { $ScanDigest } elseif ($scanFile) { Get-NormalizedScanDigest $scanFile } else { throw 'ScanDigest is required with ScanObject' }
$registry = Read-Json $PolicyRegistryPath
Assert-CleanupSchema $scan $scanSchema
Assert-ScanSemantics $scan
Assert-CleanupSchema $plan $planSchema
Assert-PlanSemantics -Plan $plan -Scan $scan -PolicyRegistry $registry -ScanDigest $resolvedScanDigest

$operationsToValidate = @($plan.operations)
if ($OperationId) {
    foreach ($id in $OperationId) {
        if (@($operationsToValidate | Where-Object operationId -eq $id).Count -ne 1) { throw "Unknown operation '$id'" }
    }
    $operationsToValidate = @($operationsToValidate | Where-Object operationId -in $OperationId)
}

$summaryParameters = @{ JsonSummary = $true }
if ($ProcessFixture) { $summaryParameters.ProcessFixture = $ProcessFixture }
$liveSummary = & (Join-Path $HelpersDirectory 'live_paths.ps1') @summaryParameters | ConvertFrom-Json -Depth 20
if ($liveSummary.status -ne 'complete') {
    throw "Process liveness census is not complete: $($liveSummary.limitations -join '; ')"
}
$pathParameters = @{}
if ($ProcessFixture) { $pathParameters.ProcessFixture = $ProcessFixture }
$livePaths = @(& (Join-Path $HelpersDirectory 'live_paths.ps1') @pathParameters)
$processNames = if ($ProcessFixture) {
    @((Read-Json $ProcessFixture).Name)
} else {
    @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object Name)
}

$checks = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($operation in $operationsToValidate) {
    $target = [string]$operation.target.canonicalPath
    $operationChecks = [System.Collections.Generic.List[object]]::new()
    function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
        $operationChecks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
        if (-not $Passed) { $failures.Add("$($operation.operationId): $Name - $Detail") }
    }

    Add-Check 'root-policy' (Test-RootPolicy $operation $scan $registry ([bool]$ProcessFixture)) $operation.preconditions.rootPolicyId
    if ($operation.preconditions.requireExists) {
        Add-Check 'exists' (Test-Path -LiteralPath $target) $target
    }
    if ($operation.preconditions.rejectReparsePoint -and (Test-Path -LiteralPath $target)) {
        $reparse = [bool]((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
        Add-Check 'not-reparse-point' (-not $reparse) $target
    }
    if ($operation.preconditions.liveness -eq 'refresh-before-execution') {
        $live = @($livePaths | Where-Object {
            $livePath = $_
            (Test-PathInside $livePath $target) -and
                @($plan.exclusions | Where-Object { Test-PathInside $livePath $_.canonicalPath }).Count -eq 0
        })
        Add-Check 'not-live' ($live.Count -eq 0) $(if ($live.Count) { $live -join ', ' } else { 'No running process path is inside target' })
        if ($operation.policyId -eq 'config-msi-leftovers') {
            $installers = @($processNames | Where-Object { $_ -in @('msiexec.exe', 'TiWorker.exe', 'TrustedInstaller.exe', 'MoUsoCoreWorker.exe') })
            Add-Check 'installer-idle' ($installers.Count -eq 0) $(if ($installers.Count) { $installers -join ', ' } else { 'No installer/update process detected' })
        }
    }
    if ($operation.preconditions.freshness -eq 'refresh-before-execution') {
        $newest = Get-NewestWrite $target
        Add-Check 'cold-for-24-hours' ($newest -le [DateTime]::UtcNow.AddHours(-24)) $newest.ToString('o')
    }
    if ($operation.preconditions.registeredMcpOwnership -eq 'refresh-before-execution') {
        Add-Check 'registered-mcp-ownership' $false 'No registered-MCP refresh provider is implemented for this policy.'
    }
    $checks.Add([ordered]@{ operationId = [string]$operation.operationId; checks = @($operationChecks) })
}

$report = [ordered]@{
    valid = $failures.Count -eq 0
    validatedAt = [DateTime]::UtcNow.ToString('o')
    scanDigest = $resolvedScanDigest
    planId = [string]$plan.planId
    sessionCensus = $liveSummary
    operations = @($checks)
    failures = @($failures)
}
if ($failures.Count -gt 0) { throw "Cleanup plan validation failed: $($failures -join '; ')" }
if (-not $Quiet) { $report | ConvertTo-Json -Depth 20 }
