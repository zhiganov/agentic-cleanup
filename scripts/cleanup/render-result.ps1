[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cleanup.Contracts.psm1') -Force
$result = [IO.File]::ReadAllText($ResultPath) | ConvertFrom-Json -Depth 100
Assert-CleanupSchema $result (Join-Path $PSScriptRoot 'schemas\result.schema.json')
$net = [long]$result.diskAfter.freeBytes - [long]$result.diskBefore.freeBytes
$rows = @($result.operations | ForEach-Object {
    [ordered]@{ operationId = $_.operationId; status = $_.status
        logicalBytesBefore = $_.bytesBefore; logicalBytesAfter = $_.bytesAfter
        netFreeSpaceChangeBytes = if ($_.PSObject.Properties['diskBefore'] -and $_.PSObject.Properties['diskAfter']) { [long]$_.diskAfter.freeBytes - [long]$_.diskBefore.freeBytes } else { $null }
        repositoryStatusUnchanged = if ($_.PSObject.Properties['repositoryStatusUnchanged']) { $_.repositoryStatusUnchanged } else { $null }
        logicalScopeDecrease = if ($null -eq $_.bytesBefore -or $null -eq $_.bytesAfter) { $null } else { [long]$_.bytesBefore - [long]$_.bytesAfter } }
})
# Scope decreases are not allocation/recovery claims; preserve negative values.
[ordered]@{ operations = $rows; netFreeSpaceChangeBytes = $net
    estimatedUniquelyReclaimedBytes = $null
    caveat = 'Net disk change includes concurrent writes and scratch. Logical scope decreases are not uniquely reclaimed storage.'
    warningCount = @($result.warnings).Count; failureCount = @($result.failures).Count } | ConvertTo-Json -Depth 10
