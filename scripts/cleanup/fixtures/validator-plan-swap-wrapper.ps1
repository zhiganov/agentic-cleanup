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
    [string]$HomePath,
    [string[]]$ClaudeConfigPath,
    [string[]]$OpenCodeConfigPath,
    [switch]$Quiet
)

& (Join-Path $PSScriptRoot 'validate-plan-real.ps1') @PSBoundParameters
if (-not $OperationId -and $env:CLEANUP_TEST_LATE_CLAUDE_CONFIG -and $env:CLEANUP_TEST_LATE_MCP_ENTRY) {
    [ordered]@{
        mcpServers = [ordered]@{
            late = [ordered]@{ command = 'node'; args = @($env:CLEANUP_TEST_LATE_MCP_ENTRY) }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:CLEANUP_TEST_LATE_CLAUDE_CONFIG -Encoding utf8NoBOM
}
if (-not $OperationId -and $env:CLEANUP_TEST_REPLACEMENT_PLAN -and $env:CLEANUP_TEST_ACTIVE_PLAN) {
    Copy-Item -LiteralPath $env:CLEANUP_TEST_REPLACEMENT_PLAN -Destination $env:CLEANUP_TEST_ACTIVE_PLAN -Force
}
