$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scanSchema = Join-Path $root 'schemas\scan.schema.json'
$planSchema = Join-Path $root 'schemas\plan.schema.json'
$scanFixture = Join-Path $root 'fixtures\windows-scan.json'
$planFixture = Join-Path $root 'fixtures\windows-plan.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

function Test-Instance([object]$Value, [string]$SchemaFile) {
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    return $json | Test-Json -SchemaFile $SchemaFile -ErrorAction SilentlyContinue
}

function Get-NormalizedJsonDigest([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$scan = Get-Content -LiteralPath $scanFixture -Raw | ConvertFrom-Json -Depth 100
$plan = Get-Content -LiteralPath $planFixture -Raw | ConvertFrom-Json -Depth 100

Assert-True (Test-Instance $scan $scanSchema) 'Windows scan fixture matches scan.schema.json'
Assert-True (Test-Instance $plan $planSchema) 'Windows plan fixture matches plan.schema.json'

$scanWithoutRunId = $scan.PSObject.Copy()
$scanWithoutRunId.PSObject.Properties.Remove('runId')
Assert-True (-not (Test-Instance $scanWithoutRunId $scanSchema)) 'Scan rejects a missing runId'

$planWithCommand = $plan.PSObject.Copy()
$planWithCommand.operations[0] | Add-Member -NotePropertyName command -NotePropertyValue 'npm cache clean --force'
Assert-True (-not (Test-Instance $planWithCommand $planSchema)) 'Plan rejects an arbitrary command field'

$planWithEmptyBucket = Get-Content -LiteralPath $planFixture -Raw | ConvertFrom-Json -Depth 100
$planWithEmptyBucket.assertionBuckets[0].minimumOperationCount = 0
Assert-True (-not (Test-Instance $planWithEmptyBucket $planSchema)) 'Plan rejects an empty selected-category bucket'

$protectedNpx = @($scan.categories.items.resources | Where-Object resourceId -eq 'npm-npx')
Assert-True ($protectedNpx.Count -eq 1 -and $protectedNpx[0].protected) 'Scan fixture marks npm _npx as protected'

$freeformFields = @('command', 'script', 'arguments', 'argumentVector', 'shell')
$planSchemaText = Get-Content -LiteralPath $planSchema -Raw
foreach ($field in $freeformFields) {
    Assert-True (-not ($planSchemaText -match ('"' + [regex]::Escape($field) + '"\s*:'))) "Plan schema exposes no '$field' property"
}

$validPlan = Get-Content -LiteralPath $planFixture -Raw | ConvertFrom-Json -Depth 100
$scanDigest = Get-NormalizedJsonDigest $scanFixture
Assert-True ($validPlan.runId -eq $scan.runId) 'Plan references the scan runId'
Assert-True ($validPlan.scan.digestAlgorithm -eq 'sha256-utf8-lf-v1') 'Plan declares the normalized scan digest algorithm'
Assert-True ($validPlan.scan.sha256 -eq $scanDigest) 'Plan references the immutable scan text after line-ending normalization'

$crlfCopy = [IO.Path]::GetTempFileName()
try {
    $scanText = [IO.File]::ReadAllText($scanFixture).Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($crlfCopy, $scanText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    Assert-True ((Get-NormalizedJsonDigest $crlfCopy) -eq $scanDigest) 'Scan digest is stable across LF and CRLF checkouts'
} finally {
    Remove-Item -LiteralPath $crlfCopy -Force -ErrorAction SilentlyContinue
}

$selectedCategories = @($validPlan.selection.categoryIds | Sort-Object -Unique)
$bucketCategories = @($validPlan.assertionBuckets.categoryId | Sort-Object -Unique)
Assert-True (-not (Compare-Object $selectedCategories $bucketCategories)) 'Every selected category has one assertion bucket'

foreach ($bucket in $validPlan.assertionBuckets) {
    $count = @($validPlan.operations | Where-Object categoryId -eq $bucket.categoryId).Count
    Assert-True ($count -ge $bucket.minimumOperationCount) "Category '$($bucket.categoryId)' meets its minimum operation count"
}

foreach ($operation in $validPlan.operations) {
    Assert-True ($operation.categoryId -in $validPlan.selection.categoryIds) "Operation '$($operation.operationId)' maps to a selected category"
    Assert-True ($operation.itemId -in $validPlan.selection.itemIds) "Operation '$($operation.operationId)' maps to a selected item"

    $category = @($scan.categories | Where-Object categoryId -eq $operation.categoryId)
    $item = @($category.items | Where-Object itemId -eq $operation.itemId)
    $resource = @($item.resources | Where-Object resourceId -eq $operation.target.resourceId)
    Assert-True ($category.Count -eq 1) "Operation '$($operation.operationId)' category exists once in the scan"
    Assert-True ($item.Count -eq 1) "Operation '$($operation.operationId)' item exists once in the scan category"
    Assert-True ($resource.Count -eq 1) "Operation '$($operation.operationId)' resource exists once in the scan item"
    Assert-True (-not $resource[0].protected) "Operation '$($operation.operationId)' does not target a protected resource"
}

Write-Output 'All cleanup schema tests passed.'
