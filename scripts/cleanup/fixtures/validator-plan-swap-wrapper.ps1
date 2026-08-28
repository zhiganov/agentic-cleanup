[CmdletBinding()]
param(
    [string]$ScanPath,
    [string]$PlanPath,
    [object]$ScanObject,
    [object]$PlanObject,
    [string]$ScanDigest,
    [string[]]$OperationId,
    [string]$PolicyRegistryPath,
    [string]$HelpersDirectory,
    [string]$ProcessFixture,
    [switch]$Quiet
)

& (Join-Path $PSScriptRoot 'validate-plan-real.ps1') @PSBoundParameters
if (-not $OperationId -and $env:CLEANUP_TEST_REPLACEMENT_PLAN -and $env:CLEANUP_TEST_ACTIVE_PLAN) {
    Copy-Item -LiteralPath $env:CLEANUP_TEST_REPLACEMENT_PLAN -Destination $env:CLEANUP_TEST_ACTIVE_PLAN -Force
}
