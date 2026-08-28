$ErrorActionPreference = 'Stop'

$cleanupRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path (Split-Path -Parent $cleanupRoot) 'windows\cleanup\live_paths.ps1'
$fixture = Join-Path $cleanupRoot 'fixtures\windows-processes.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

$summary = & $script -JsonSummary -ProcessFixture $fixture | ConvertFrom-Json
$sessions = @($summary.sessions)
$claude = @($sessions | Where-Object runtime -eq 'claude-code')
$openCode = @($sessions | Where-Object runtime -eq 'opencode')

Assert-True ($summary.status -eq 'complete') 'Structured census reports complete fixture processing'
Assert-True ($sessions.Count -eq 4) 'Structured census includes every Claude and OpenCode runtime process'
Assert-True ($claude.Count -eq 2) 'Structured census keeps multiple Claude sessions as an array'
Assert-True (($claude | Where-Object sessionId -eq 'session-one').serverCount -eq 1) 'Claude MCP server is attributed through its parent chain'
Assert-True (($claude | Where-Object sessionId -eq 'Session Two').serverCount -eq 0) 'Quoted Claude session names remain intact'
Assert-True ($openCode.Count -eq 2) 'Structured census includes OpenCode service and client processes'
Assert-True (($openCode | Where-Object pid -eq 300).serverCount -eq 1) 'OpenCode service descendant count is reported'
Assert-True (-not ($openCode | Where-Object sessionId)) 'OpenCode process ancestry does not invent exact session IDs'
Assert-True (@($summary.limitations).Count -eq 1) 'OpenCode shared-service limitation is explicit'

$failed = & $script -JsonSummary -ProcessFixture (Join-Path $cleanupRoot 'fixtures\missing-processes.json') | ConvertFrom-Json
Assert-True ($failed.status -eq 'failed') 'Process enumeration failure is not reported as an empty complete census'
Assert-True ($failed.limitations[0] -match 'Process enumeration failed') 'Process enumeration failure remains visible'

Write-Output 'All live-path census tests passed.'
