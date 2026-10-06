[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScanPath,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ContractDirectory,
    [string]$PolicyRegistryPath,
    [string]$HomePath = $HOME,
    [string[]]$ClaudeConfigPath,
    [string[]]$OpenCodeConfigPath,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$contractCandidates = @(
    $ContractDirectory,
    (Join-Path $PSScriptRoot '..\..\cleanup'),
    (Join-Path $PSScriptRoot '..\cleanup-contracts')
) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'Cleanup.Contracts.psm1')) }
if (@($contractCandidates).Count -eq 0) { throw 'Could not locate cleanup contract directory' }
$contractRoot = Resolve-Path @($contractCandidates)[0]
if (-not $PolicyRegistryPath) { $PolicyRegistryPath = Join-Path $contractRoot 'policies\windows.v1.json' }
Import-Module (Join-Path $contractRoot 'Cleanup.Contracts.psm1') -Force
. (Join-Path $PSScriptRoot 'path_evidence.ps1')
$validator = Join-Path $contractRoot 'validate-plan.ps1'
$resultSchema = Join-Path $contractRoot 'schemas\result.schema.json'

function Read-JsonDocument([string]$Path) {
    $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path)).TrimStart([char]0xFEFF)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    [ordered]@{
        value = $text | ConvertFrom-Json -Depth 100
        digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Get-PathBytes([string]$Path) {
    try { [long](Get-CleanupTreeEvidence $Path).logicalBytes }
    catch [System.Management.Automation.ItemNotFoundException] { return 0L }
    catch { return $null } # unavailable metadata is not zero bytes
}

function Get-DiskSnapshot([string]$Path) {
    $driveName = ([IO.Path]::GetPathRoot($Path)).TrimEnd('\').TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName
    [ordered]@{ capturedAt = [DateTime]::UtcNow.ToString('o'); freeBytes = [long]$drive.Free; totalBytes = [long]($drive.Used + $drive.Free) }
}

function Test-PathInside([string]$Path, [string]$Root, [string]$Relationship) {
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Relationship -eq 'exact') { return $false }
    $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RepositoryStatusDigest([string]$Path) {
    $current = Split-Path -Parent $Path
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
            $rows = @(& git -C $current status --porcelain=v1 --untracked-files=normal 2>$null)
            if ($LASTEXITCODE -ne 0) { return $null }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
            return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        }
        if ($current -eq $scan.workspace.root) { break }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $null
}

$scanDocument = Read-JsonDocument $ScanPath
$planDocument = Read-JsonDocument $PlanPath
$scan = $scanDocument.value
$plan = $planDocument.value
$scanDigest = $scanDocument.digest
$validationParameters = @{
    ScanObject = $scan
    PlanObject = $plan
    ScanDigest = $scanDigest
    PolicyRegistryPath = $PolicyRegistryPath
    HelpersDirectory = $PSScriptRoot
    HomePath = $HomePath
    ClaudeConfigPath = $ClaudeConfigPath
    OpenCodeConfigPath = $OpenCodeConfigPath
    Quiet = $true
    AllowAbsentTargets = $true
}
& $validator @validationParameters
$started = [DateTime]::UtcNow
$diskBefore = Get-DiskSnapshot $scan.workspace.root
$results = [System.Collections.Generic.List[object]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
function Add-OperationResult([object]$Row) {
    $Row.diskBefore = $operationDiskBefore
    $Row.diskAfter = Get-DiskSnapshot $scan.workspace.root
    $repositoryStatusAfter = Get-RepositoryStatusDigest $target
    $Row.repositoryStatusUnchanged = if ($null -ne $repositoryStatusBefore -and $null -ne $repositoryStatusAfter) { $repositoryStatusBefore -eq $repositoryStatusAfter } else { $null }
    if ($Row.repositoryStatusUnchanged -eq $false) { [void]$warnings.Add("$($operation.operationId): repository status changed; do not attribute or revert concurrent work.") }
    $results.Add($Row)
}
:operationLoop foreach ($operation in @($plan.operations)) {
    $target = [string]$operation.target.canonicalPath
    $repositoryStatusBefore = Get-RepositoryStatusDigest $target
    $operationDiskBefore = Get-DiskSnapshot $scan.workspace.root
    try {
        & $validator @validationParameters -OperationId $operation.operationId
    } catch {
        $message = "Precondition failed immediately before execution: $($_.Exception.Message)"
        [void]$failures.Add("$($operation.operationId): $message")
        $unchangedBytes = Get-PathBytes $target
        Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = 'failed'; bytesBefore = $unchangedBytes; bytesAfter = $unchangedBytes; message = $message })
        continue
    }
    $before = Get-PathBytes $target
    if (-not (Test-Path -LiteralPath $target) -and $operation.policyId -in @('inactive-build-artifact', 'inactive-node-modules', 'build-cache-contents')) {
        Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = 'validated-noop'; bytesBefore = 0L; bytesAfter = 0L; message = 'Exact approved target is absent after refresh; no replacement scope was selected.' })
        continue
    }
    if ($WhatIf) {
        Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = 'validated-noop'; bytesBefore = $before; bytesAfter = $before; message = 'Plan validated; no mutation requested.' })
        continue
    }
    $operationDiskBefore = Get-DiskSnapshot $scan.workspace.root
    try {
        $lockedSkip = $false
        $removeCompleted = $false
        switch ($operation.executorId) {
            'remove-directory-tree' {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                $removeCompleted = $true
            }
            'clear-directory-contents' {
                if (-not (Get-Item -LiteralPath $target -Force -ErrorAction Stop).PSIsContainer) { throw 'Contents-only target is no longer a directory' }
                $mandatoryDenies = @(
                    [IO.Path]::GetFullPath((Join-Path $env:TEMP 'claude')),
                    [IO.Path]::GetFullPath((Join-Path $env:TEMP 'opencode')),
                    [IO.Path]::GetFullPath((Join-Path $env:TEMP 'agentic-cleanup')),
                    [IO.Path]::GetFullPath((Join-Path $env:TEMP 'claude-cleanup'))
                )
                foreach ($child in @(Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop)) {
                    $excluded = @($plan.exclusions | Where-Object { Test-PathInside $child.FullName $_.canonicalPath $_.relationship })
                    $mandatoryDenied = @($mandatoryDenies | Where-Object { Test-PathInside $child.FullName $_ 'subtree' }).Count -gt 0
                    if ($excluded.Count -gt 0 -or $mandatoryDenied) { continue }
                    try {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked child preserved' }
                        Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
                    }
                    catch {
                        $lockedSkip = $true
                        [void]$warnings.Add("$($operation.operationId): locked/skipped '$($child.FullName)': $($_.Exception.Message)")
                    }
                }
            }
            'npm-cache-clean' {
                if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm is not installed' }
                & npm cache clean --force
                if ($LASTEXITCODE -ne 0) { throw "npm cache clean exited $LASTEXITCODE" }
            }
            'remove-directory-tree-elevated' {
                if (-not (Test-IsAdministrator)) {
                    Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = 'manual-required'; bytesBefore = $before; bytesAfter = $before; message = 'Run the committed executor from an already elevated trusted process; automatic UAC launching is intentionally unavailable.' })
                    continue operationLoop
                }
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                $removeCompleted = $true
            }
            'show-windows-storage-instructions' {
                Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = 'manual-required'; bytesBefore = $before; bytesAfter = $before; message = 'Use Settings > System > Storage > Temporary files.' })
                continue operationLoop
            }
            default { throw "Executor '$($operation.executorId)' is not implemented" }
        }
        $after = Get-PathBytes $target
        $status = switch ($operation.mode) {
            'contents-only' {
                $remainingManagedChildren = @(
                    Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue |
                        Where-Object {
                            $candidate = $_.FullName
                            @($plan.exclusions | Where-Object { Test-PathInside $candidate $_.canonicalPath $_.relationship }).Count -eq 0 -and
                            @($mandatoryDenies | Where-Object { Test-PathInside $candidate $_ 'subtree' }).Count -eq 0
                        }
                )
                if ($lockedSkip) { 'locked-skipped' } elseif ($remainingManagedChildren.Count -gt 0) { 'recreated' } else { 'contents-cleared' }
            }
            'tool-command' { if ($after -eq 0) { 'contents-cleared' } elseif ($after -lt $before) { 'recreated' } else { 'recreated' } }
            default { if (-not (Test-Path -LiteralPath $target)) { 'removed' } elseif ($removeCompleted) { 'recreated' } else { 'failed' } }
        }
        if ($status -eq 'failed') { [void]$failures.Add("$($operation.operationId): target remains unchanged") }
        Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = $status; bytesBefore = $before; bytesAfter = $after; message = "Executor '$($operation.executorId)' completed with status '$status'." })
    } catch {
        [void]$failures.Add("$($operation.operationId): $($_.Exception.Message)")
        Add-OperationResult ([ordered]@{ operationId = $operation.operationId; status = 'failed'; bytesBefore = $before; bytesAfter = Get-PathBytes $target; message = $_.Exception.Message })
    }
}

$result = [ordered]@{
    schemaVersion = '1.0'; resultId = [guid]::NewGuid().ToString(); planId = [string]$plan.planId; runId = [string]$plan.runId
    startedAt = $started.ToString('o'); completedAt = [DateTime]::UtcNow.ToString('o')
    diskBefore = $diskBefore; diskAfter = Get-DiskSnapshot $scan.workspace.root
    operations = @($results); warnings = @($warnings); failures = @($failures)
}
Assert-CleanupSchema $result $resultSchema
Write-ImmutableJson $result ([IO.Path]::GetFullPath($OutputPath))
Write-Output ([IO.Path]::GetFullPath($OutputPath))
