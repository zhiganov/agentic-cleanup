[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScanPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string[]]$CategoryId,
    [string[]]$ItemId = @(),
    [string[]]$ConfirmedItemId = @(),
    [string]$PolicyRegistryPath = (Join-Path $PSScriptRoot 'policies\windows.v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cleanup.Contracts.psm1') -Force
$scanSchema = Join-Path $PSScriptRoot 'schemas\scan.schema.json'
$planSchema = Join-Path $PSScriptRoot 'schemas\plan.schema.json'

function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function Get-OperationId([object]$Item, [object]$Resource, [object]$Policy) {
    $identity = "$($Item.itemId)|$($Resource.resourceId)|$($Policy.policyId)|$($Policy.mode)"
    $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 12)
    "operation-$hash"
}

$scanFile = [IO.Path]::GetFullPath($ScanPath)
$outputFile = [IO.Path]::GetFullPath($OutputPath)
$scan = Read-Json $scanFile
$registry = Read-Json $PolicyRegistryPath
Assert-CleanupSchema $scan $scanSchema
Assert-ScanSemantics $scan

$selectedCategories = @($CategoryId | Sort-Object -Unique)
if ($selectedCategories.Count -ne @($CategoryId).Count) { throw 'Category selection contains duplicates' }
$knownCategories = @($scan.categories.categoryId)
foreach ($id in $selectedCategories) {
    if ($id -notin $knownCategories) { throw "Unknown selected category '$id'" }
}
$requestedItems = @($ItemId | Sort-Object -Unique)
if ($requestedItems.Count -ne @($ItemId).Count) { throw 'Item selection contains duplicates' }
$knownItems = @($scan.categories.items.itemId)
foreach ($id in @($requestedItems + $ConfirmedItemId)) {
    if ($id -notin $knownItems) { throw "Unknown selected or confirmed item '$id'" }
}

$operations = [System.Collections.Generic.List[object]]::new()
$selectedItems = [System.Collections.Generic.List[string]]::new()
$buckets = [System.Collections.Generic.List[object]]::new()
foreach ($selectedCategory in $selectedCategories) {
    $category = @($scan.categories | Where-Object categoryId -eq $selectedCategory)[0]
    $eligibleItems = @($category.items | Where-Object { $_.disposition -in @('eligible', 'manual-only') })
    if ($requestedItems.Count -gt 0) { $eligibleItems = @($eligibleItems | Where-Object itemId -in $requestedItems) }
    foreach ($item in $eligibleItems) {
        if ($item.requiresPerItemConfirmation -and $item.itemId -notin $ConfirmedItemId) { continue }
        $policy = @($registry.policies | Where-Object policyId -eq $item.operationPreview.policyId)
        if ($policy.Count -ne 1) { throw "No unique policy for item '$($item.itemId)'" }
        $targetResources = @($item.resources | Where-Object { -not $_.protected })
        if ($targetResources.Count -eq 0) { continue }
        [void]$selectedItems.Add([string]$item.itemId)
        foreach ($resource in $targetResources) {
            $operations.Add([ordered]@{
                operationId = Get-OperationId $item $resource $policy[0]
                categoryId = [string]$category.categoryId
                itemId = [string]$item.itemId
                policyId = [string]$policy[0].policyId
                executorId = [string]$policy[0].executorId
                mode = [string]$policy[0].mode
                elevated = [bool]$policy[0].elevated
                confirmation = if ($item.requiresPerItemConfirmation) { 'item-confirmed' } else { 'category-selected' }
                target = [ordered]@{
                    resourceId = [string]$resource.resourceId
                    canonicalPath = $resource.canonicalPath
                    expectedKind = [string]$resource.kind
                    expectedLogicalBytes = [long]$resource.logicalBytes
                }
                preconditions = [ordered]@{
                    rootPolicyId = [string]$policy[0].rootPolicyId
                    requireExists = [bool]$policy[0].preconditions.requireExists
                    rejectReparsePoint = [bool]$policy[0].preconditions.rejectReparsePoint
                    liveness = [string]$policy[0].preconditions.liveness
                    freshness = [string]$policy[0].preconditions.freshness
                    registeredMcpOwnership = [string]$policy[0].preconditions.registeredMcpOwnership
                }
                affectedApplications = @($item.affectedApplications)
            })
        }
    }
    $count = @($operations | Where-Object categoryId -eq $selectedCategory).Count
    if ($count -eq 0) { throw "Selected category '$selectedCategory' produced no operations" }
    $buckets.Add([ordered]@{ categoryId = $selectedCategory; minimumOperationCount = 1 })
}
foreach ($id in $requestedItems) {
    if ($id -notin $selectedItems) { throw "Requested item '$id' did not produce an operation in the selected categories" }
}
foreach ($id in $ConfirmedItemId) {
    if ($id -notin $selectedItems) { throw "Confirmed item '$id' is not part of the resulting plan" }
}

$exclusions = [System.Collections.Generic.List[object]]::new()
$npmNpx = @($scan.categories.items.resources | Where-Object resourceId -eq 'npm-npx')
if ($npmNpx.Count -eq 1 -and $npmNpx[0].canonicalPath) {
    $exclusions.Add([ordered]@{ policyId = 'protect-npm-npx'; canonicalPath = $npmNpx[0].canonicalPath; relationship = 'subtree'; reason = 'Live MCP servers execute from _npx' })
}
$tempRoot = @($scan.categories.items.resources | Where-Object resourceId -eq 'user-temp-root')
if ($tempRoot.Count -eq 1 -and $tempRoot[0].canonicalPath) {
    $exclusions.Add([ordered]@{ policyId = 'protect-cleanup-scratch'; canonicalPath = [IO.Path]::GetFullPath((Join-Path $tempRoot[0].canonicalPath 'agentic-cleanup')); relationship = 'subtree'; reason = 'Current cleanup run scratch and scan snapshot' })
    $exclusions.Add([ordered]@{ policyId = 'protect-legacy-cleanup-scratch'; canonicalPath = [IO.Path]::GetFullPath((Join-Path $tempRoot[0].canonicalPath 'claude-cleanup')); relationship = 'subtree'; reason = 'Pre-rename cleanup run scratch' })
    $exclusions.Add([ordered]@{ policyId = 'protect-runtime-scratch'; canonicalPath = [IO.Path]::GetFullPath((Join-Path $tempRoot[0].canonicalPath 'claude')); relationship = 'subtree'; reason = 'Live runtime scratch' })
    $exclusions.Add([ordered]@{ policyId = 'protect-opencode-runtime-scratch'; canonicalPath = [IO.Path]::GetFullPath((Join-Path $tempRoot[0].canonicalPath 'opencode')); relationship = 'subtree'; reason = 'Live OpenCode runtime scratch' })
}

$now = [DateTime]::UtcNow.ToString('o')
$plan = [ordered]@{
    schemaVersion = '1.0'; planId = [guid]::NewGuid().ToString(); runId = [string]$scan.runId; createdAt = $now
    scan = [ordered]@{ schemaVersion = [string]$scan.schemaVersion; digestAlgorithm = 'sha256-utf8-lf-v1'; sha256 = Get-NormalizedScanDigest $scanFile; createdAt = [string]$scan.createdAt }
    selection = [ordered]@{ source = 'interactive-user-selection'; selectedAt = $now; categoryIds = $selectedCategories; itemIds = @($selectedItems | Sort-Object -Unique) }
    assertionBuckets = @($buckets); operations = @($operations); exclusions = @($exclusions)
}

Assert-CleanupSchema $plan $planSchema
Assert-PlanSemantics $plan $scan $scanFile $registry
Write-ImmutableJson $plan $outputFile
Write-Output $outputFile
