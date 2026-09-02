$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $root 'build-plan.ps1'
$scan = Join-Path $root 'fixtures\windows-scan.json'
$output = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-plan-{0}.json" -f [guid]::NewGuid())

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

try {
    $categories = @('package-manager-caches', 'windows-temp-files', 'build-artifacts', 'config-msi-leftovers', 'windows-old')
    & $builder -ScanPath $scan -OutputPath $output -CategoryId $categories | Out-Null
    $plan = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 100
    Assert-True (@($plan.selection.categoryIds).Count -eq 5) 'Builder records stable selected category IDs'
    Assert-True (@($plan.assertionBuckets).Count -eq 5) 'Builder creates one assertion bucket per selected category'
    Assert-True (@($plan.operations).Count -eq 5) 'Builder maps representative categories to allowlisted operations'
    Assert-True (-not ($plan.operations.PSObject.Properties.Name -contains 'command')) 'Builder emits no executable command field'
    Assert-True (@($plan.exclusions | Where-Object policyId -eq 'protect-npm-npx').Count -eq 1) 'Builder carries the npm _npx exclusion'
    Assert-True (@($plan.exclusions | Where-Object policyId -eq 'protect-legacy-cleanup-scratch').Count -eq 1) 'Builder carries the pre-rename cleanup scratch exclusion'
    Assert-True (@($plan.exclusions | Where-Object policyId -eq 'protect-runtime-scratch').Count -eq 1) 'Builder carries the runtime scratch exclusion'
    Assert-True (@($plan.exclusions | Where-Object policyId -eq 'protect-opencode-runtime-scratch').Count -eq 1) 'Builder carries the OpenCode runtime scratch exclusion'
} finally {
    Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
}

$itemOutput = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-plan-item-{0}.json" -f [guid]::NewGuid())
try {
    & $builder -ScanPath $scan -OutputPath $itemOutput -CategoryId 'build-artifacts' -ItemId 'project-a-next' | Out-Null
    $itemPlan = Get-Content -LiteralPath $itemOutput -Raw | ConvertFrom-Json -Depth 100
    Assert-True (@($itemPlan.selection.itemIds).Count -eq 1 -and $itemPlan.selection.itemIds[0] -eq 'project-a-next') 'Builder persists exact per-item selection'
} finally {
    Remove-Item -LiteralPath $itemOutput -Force -ErrorAction SilentlyContinue
}

$nodeScanPath = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-node-scan-{0}.json" -f [guid]::NewGuid())
$nodeOutput = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-node-plan-{0}.json" -f [guid]::NewGuid())
try {
    $nodeScan = Get-Content -LiteralPath $scan -Raw | ConvertFrom-Json -Depth 100
    $nodeScan.categories = @($nodeScan.categories) + @([ordered]@{
        categoryId = 'node-modules'; label = 'node_modules (Inactive)'; status = 'found'; statusReason = $null
        sizes = [ordered]@{ logicalBytes = 1024; estimatedReclaimableBytes = 1024; protectedBytes = 0 }
        items = @([ordered]@{
            itemId = 'node-modules-fixture'; displayName = 'fixture node_modules'; disposition = 'eligible'
            sizes = [ordered]@{ logicalBytes = 1024; estimatedReclaimableBytes = 1024; protectedBytes = 0 }
            resources = @([ordered]@{ resourceId = 'node-modules-fixture-dir'; kind = 'directory'; canonicalPath = 'C:\Users\example\workspace\fixture\node_modules'; logicalBytes = 1024; protected = $false })
            operationPreview = [ordered]@{ policyId = 'inactive-node-modules'; mode = 'whole-directory'; elevated = $false }
            evidence = @(); riskFlags = @('refresh-liveness', 'refresh-registered-mcp-ownership'); requiresPerItemConfirmation = $false; affectedApplications = @()
        })
        warnings = @()
    })
    $nodeScan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $nodeScanPath -Encoding utf8NoBOM
    & $builder -ScanPath $nodeScanPath -OutputPath $nodeOutput -CategoryId 'node-modules' | Out-Null
    $nodePlan = Get-Content -LiteralPath $nodeOutput -Raw | ConvertFrom-Json -Depth 100
    $nodeOperation = @($nodePlan.operations)[0]
    Assert-True ($nodeOperation.policyId -eq 'inactive-node-modules' -and $nodeOperation.executorId -eq 'remove-directory-tree') 'Builder maps node_modules to the allowlisted removal policy'
    Assert-True ($nodeOperation.preconditions.rootPolicyId -eq 'workspace-node-modules-root') 'Builder carries the node_modules workspace root policy'
    Assert-True ($nodeOperation.preconditions.registeredMcpOwnership -eq 'refresh-before-execution') 'Builder requires registered MCP ownership refresh for node_modules'
} finally {
    Remove-Item -LiteralPath $nodeScanPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $nodeOutput -Force -ErrorAction SilentlyContinue
}

$emptyOutput = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-plan-empty-{0}.json" -f [guid]::NewGuid())
try {
    try {
        & $builder -ScanPath $scan -OutputPath $emptyOutput -CategoryId 'missing-category' | Out-Null
        throw 'FAIL: Builder accepted an unknown category'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Builder accepted an unknown category') { throw }
        Write-Output 'PASS: Builder rejects unknown categories'
    }
} finally {
    Remove-Item -LiteralPath $emptyOutput -Force -ErrorAction SilentlyContinue
}


$unknownItemOutput = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-plan-unknown-item-{0}.json" -f [guid]::NewGuid())
try {
    try {
        & $builder -ScanPath $scan -OutputPath $unknownItemOutput -CategoryId 'build-artifacts' -ItemId 'missing-item' | Out-Null
        throw 'FAIL: Builder accepted an unknown item'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Builder accepted an unknown item') { throw }
        Write-Output 'PASS: Builder rejects unknown item selections'
    }
} finally {
    Remove-Item -LiteralPath $unknownItemOutput -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup plan-builder tests passed.'
