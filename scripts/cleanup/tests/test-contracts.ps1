$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Cleanup.Contracts.psm1') -Force
$scanPath = Join-Path $root 'fixtures\windows-scan.json'
$planPath = Join-Path $root 'fixtures\windows-plan.json'
$policyPath = Join-Path $root 'policies\windows.v1.json'
$scanSchema = Join-Path $root 'schemas\scan.schema.json'
$planSchema = Join-Path $root 'schemas\plan.schema.json'

function Assert-Pass([scriptblock]$Action, [string]$Message) {
    & $Action
    Write-Output "PASS: $Message"
}

function Assert-Fails([scriptblock]$Action, [string]$Message) {
    try { & $Action; throw "FAIL: $Message" } catch {
        if ($_.Exception.Message -eq "FAIL: $Message") { throw }
        Write-Output "PASS: $Message"
    }
}

function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

$scan = Read-Json $scanPath
$plan = Read-Json $planPath
$policies = Read-Json $policyPath
Assert-Pass { Assert-CleanupSchema $scan $scanSchema; Assert-ScanSemantics $scan } 'Valid scan passes production schema and semantic validation'
Assert-Pass { Assert-CleanupSchema $plan $planSchema; Assert-PlanSemantics $plan $scan $scanPath $policies } 'Valid plan passes production schema and semantic validation'

$unknownExecutor = Read-Json $planPath
$unknownExecutor.operations[0].executorId = 'unknown-executor'
Assert-Fails { Assert-PlanSemantics $unknownExecutor $scan $scanPath $policies } 'Unknown executor is rejected through policy matching'

$targetMismatch = Read-Json $planPath
$targetMismatch.operations[0].target.expectedLogicalBytes++
Assert-Fails { Assert-PlanSemantics $targetMismatch $scan $scanPath $policies } 'Operation target metadata must equal scan evidence'

$relativePath = Read-Json $scanPath
$relativePath.workspace.cwd = 'relative\workspace'
Assert-Fails { Assert-ScanSemantics $relativePath } 'Relative Windows paths are rejected'

$duplicateBucket = Read-Json $planPath
$duplicateBucket.assertionBuckets += $duplicateBucket.assertionBuckets[0]
Assert-Fails { Assert-PlanSemantics $duplicateBucket $scan $scanPath $policies } 'Duplicate assertion buckets are rejected'

$extraSelectedItem = Read-Json $planPath
$extraSelectedItem.selection.itemIds += 'unmapped-item'
Assert-Fails { Assert-PlanSemantics $extraSelectedItem $scan $scanPath $policies } 'Selected items without operations are rejected'

$duplicateTarget = Read-Json $planPath
$duplicateTarget.operations[1].target.resourceId = $duplicateTarget.operations[0].target.resourceId
Assert-Fails { Assert-PlanSemantics $duplicateTarget $scan $scanPath $policies } 'Duplicate operation targets are rejected'

$missingExclusions = Read-Json $planPath
$missingExclusions.exclusions = @()
Assert-Fails { Assert-PlanSemantics $missingExclusions $scan $scanPath $policies } 'Mandatory protected exclusions cannot be removed'

$missingOpenCodeExclusion = Read-Json $planPath
$missingOpenCodeExclusion.exclusions = @($missingOpenCodeExclusion.exclusions | Where-Object policyId -ne 'protect-opencode-runtime-scratch')
Assert-Fails { Assert-PlanSemantics $missingOpenCodeExclusion $scan $scanPath $policies } 'OpenCode runtime scratch exclusion cannot be removed'

$badTotals = Read-Json $scanPath
$badTotals.categories[0].sizes.protectedBytes++
Assert-Fails { Assert-ScanSemantics $badTotals } 'Category size totals must match item totals'

$perItem = Read-Json $scanPath
$perItem.categories[0].items[0].requiresPerItemConfirmation = $true
Assert-Fails { Assert-PlanSemantics $plan $perItem $scanPath $policies } 'Required per-item confirmation is enforced'

$tampered = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-scan-{0}.json" -f [guid]::NewGuid())
$immutable = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-immutable-{0}.json" -f [guid]::NewGuid())
try {
    Copy-Item -LiteralPath $scanPath -Destination $tampered
    Add-Content -LiteralPath $tampered -Value ' '
    Assert-Fails { Assert-PlanSemantics $plan $scan $tampered $policies } 'Tampered scan text is rejected by digest'
    Assert-Pass { Write-ImmutableJson $scan $immutable } 'Immutable writer creates a new JSON document'
    Assert-Fails { Write-ImmutableJson $scan $immutable } 'Immutable writer refuses to overwrite an existing document'
} finally {
    Remove-Item -LiteralPath $tampered, $immutable -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup contract tests passed.'
