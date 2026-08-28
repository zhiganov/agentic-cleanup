[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScanPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cleanup.Contracts.psm1') -Force
$scan = Get-Content -LiteralPath $ScanPath -Raw | ConvertFrom-Json -Depth 100
Assert-CleanupSchema $scan (Join-Path $PSScriptRoot 'schemas\scan.schema.json')
Assert-ScanSemantics $scan

function Format-Bytes($Bytes) {
    if ($null -eq $Bytes) { return 'unknown' }
    $value = [double]$Bytes
    if ($value -ge 1GB) { return ('{0:N2} GB' -f ($value / 1GB)) }
    if ($value -ge 1MB) { return ('{0:N1} MB' -f ($value / 1MB)) }
    if ($value -ge 1KB) { return ('{0:N1} KB' -f ($value / 1KB)) }
    return "$([long]$value) B"
}

Write-Output "Run: $($scan.runId)"
Write-Output "Workspace: $($scan.workspace.root)"
Write-Output "Category ID`tStatus`tReclaimable`tProtected`tItems"
foreach ($category in @($scan.categories | Sort-Object categoryId)) {
    $items = @($category.items | ForEach-Object itemId) -join ', '
    Write-Output "$($category.categoryId)`t$($category.status)`t$(Format-Bytes $category.sizes.estimatedReclaimableBytes)`t$(Format-Bytes $category.sizes.protectedBytes)`t$items"
}
