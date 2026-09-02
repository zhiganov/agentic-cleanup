$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'windows\cleanup\registered_mcp.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-mcp-test-{0}" -f [guid]::NewGuid())
$originalXdgConfigHome = $env:XDG_CONFIG_HOME

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

function Write-Json([string]$Path, [object]$Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

try {
    $workspace = Join-Path $root 'workspace'
    $projectA = Join-Path $workspace 'project-a'
    $projectAB = Join-Path $workspace 'project-ab'
    [IO.Directory]::CreateDirectory($projectA) | Out-Null
    [IO.Directory]::CreateDirectory($projectAB) | Out-Null

    $claudeUser = Join-Path $root 'claude-user.json'
    Write-Json $claudeUser ([ordered]@{
        mcpServers = [ordered]@{
            user = [ordered]@{ command = 'node'; args = @((Join-Path $projectA 'dist\user.js')) }
        }
        projects = [ordered]@{
            $projectA = [ordered]@{
                mcpServers = [ordered]@{
                    local = [ordered]@{ command = (Join-Path $projectA 'bin\server.exe'); args = @() }
                }
            }
        }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath $root -ClaudeConfigPath $claudeUser
    Assert-True ($ownership.status -eq 'complete' -and @($ownership.owners).Count -eq 2) 'Claude user and local registrations protect their project'

    $claudeProject = Join-Path $projectA '.mcp.json'
    Write-Json $claudeProject ([ordered]@{
        mcpServers = [ordered]@{
            project = [ordered]@{ command = 'node'; args = @('.\dist\project.js') }
        }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath (Join-Path $root 'empty-home')
    Assert-True (@($ownership.owners | Where-Object name -eq 'project').Count -eq 1) 'Claude project .mcp.json resolves relative launch paths'
    Remove-Item -LiteralPath $claudeProject -Force

    $openCode = Join-Path $projectA 'opencode.jsonc'
    [IO.File]::WriteAllText($openCode, @"
{
  // Disabled static registrations remain protective.
  "mcp": {
    "servers": {
      "local": { "type": "local", "command": ["node", "./dist/open.js"], "disabled": true, },
      "remote": { "type": "remote", "url": "https://example.test/mcp" },
    },
  },
}
"@, [Text.UTF8Encoding]::new($false))
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath $root -OpenCodeConfigPath $openCode -ClaudeConfigPath (Join-Path $root 'absent.json')
    Assert-True (@($ownership.owners).Count -eq 1 -and $ownership.owners[0].name -eq 'local') 'OpenCode V2 JSONC local registration is protective and remote registration is ignored'
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectAB -WorkspaceRoot $workspace -HomePath $root -OpenCodeConfigPath $openCode -ClaudeConfigPath (Join-Path $root 'absent.json')
    Assert-True (@($ownership.owners).Count -eq 0) 'Relative explicit OpenCode project registration does not protect a neighboring project'
    Remove-Item -LiteralPath $openCode -Force

    $claudeGlobalHome = Join-Path $root 'claude-global-home'
    Write-Json (Join-Path $claudeGlobalHome '.claude.json') ([ordered]@{
        mcpServers = [ordered]@{
            relative = [ordered]@{ command = 'node'; args = @('.\dist\global.js') }
        }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath $claudeGlobalHome -OpenCodeConfigPath (Join-Path $root 'absent-opencode.json')
    Assert-True (@($ownership.owners).Count -eq 0) 'Relative Claude user registration does not protect an unrelated project'
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $claudeGlobalHome -WorkspaceRoot $root -HomePath $claudeGlobalHome -OpenCodeConfigPath (Join-Path $root 'absent-opencode.json')
    Assert-True (@($ownership.owners | Where-Object name -eq 'relative').Count -eq 1) 'Relative Claude user registration resolves from its configuration directory'

    $xdgConfigHome = Join-Path $root 'xdg-config'
    $env:XDG_CONFIG_HOME = $xdgConfigHome
    $xdgOpenCode = Join-Path $xdgConfigHome 'opencode\opencode.json'
    Write-Json $xdgOpenCode ([ordered]@{
        mcp = [ordered]@{ servers = [ordered]@{
            xdg = [ordered]@{ type = 'local'; command = @('node', (Join-Path $projectA 'dist\xdg.js')) }
        } }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath (Join-Path $root 'empty-home') -ClaudeConfigPath (Join-Path $root 'absent.json')
    Assert-True (@($ownership.owners | Where-Object name -eq 'xdg').Count -eq 1) 'OpenCode global discovery honors XDG_CONFIG_HOME'
    Write-Json $xdgOpenCode ([ordered]@{
        mcp = [ordered]@{ servers = [ordered]@{
            relative = [ordered]@{ type = 'local'; command = @('node', '.\dist\global.js') }
        } }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath (Join-Path $root 'empty-home') -ClaudeConfigPath (Join-Path $root 'absent.json')
    Assert-True (@($ownership.owners).Count -eq 0) 'Relative OpenCode global registration does not protect every candidate project'
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $workspace -WorkspaceRoot $workspace -HomePath (Join-Path $root 'empty-home') -ClaudeConfigPath (Join-Path $root 'absent.json')
    Assert-True (@($ownership.owners | Where-Object name -eq 'relative').Count -eq 1) 'Relative OpenCode global registration resolves from the active cleanup workspace'
    Remove-Item -LiteralPath $xdgOpenCode -Force

    $env:XDG_CONFIG_HOME = $null
    $ancestorRoot = Join-Path $root 'ancestor-root'
    $ancestorWorkspace = Join-Path $ancestorRoot 'workspace'
    $ancestorProject = Join-Path $ancestorWorkspace 'project'
    [IO.Directory]::CreateDirectory($ancestorProject) | Out-Null
    Write-Json (Join-Path $ancestorRoot 'opencode.json') ([ordered]@{
        mcp = [ordered]@{ servers = [ordered]@{
            ancestor = [ordered]@{ type = 'local'; command = @('node', (Join-Path $ancestorProject 'dist\ancestor.js')) }
        } }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $ancestorProject -WorkspaceRoot $ancestorWorkspace -HomePath (Join-Path $root 'empty-home') -ClaudeConfigPath (Join-Path $root 'absent.json')
    Assert-True (@($ownership.owners | Where-Object name -eq 'ancestor').Count -eq 1) 'OpenCode discovery includes config ancestors above the cleanup workspace root'
    $allAncestors = @(Get-AncestorDirectories $ancestorProject ([IO.Path]::GetPathRoot($ancestorProject)))
    Assert-True ($allAncestors[-1] -eq [IO.Path]::GetPathRoot($ancestorProject)) 'OpenCode ancestor discovery reaches the filesystem root without changing drive-root semantics'

    $boundary = Join-Path $root 'boundary.json'
    Write-Json $boundary ([ordered]@{
        mcpServers = [ordered]@{
            neighbor = [ordered]@{ command = 'node'; args = @((Join-Path $projectAB 'dist\server.js')) }
        }
    })
    $ownership = Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath $root -ClaudeConfigPath $boundary
    Assert-True (@($ownership.owners).Count -eq 0) 'Separator-aware ownership does not confuse project-a with project-ab'

    $serialized = $ownership | ConvertTo-Json -Depth 20
    Assert-True ($serialized -notmatch 'command|args|disabled') 'Ownership evidence does not expose command vectors or server settings'

    $malformed = Join-Path $root 'malformed.json'
    [IO.File]::WriteAllText($malformed, '{ invalid', [Text.UTF8Encoding]::new($false))
    try {
        Get-RegisteredMcpOwnership -ProjectPath $projectA -WorkspaceRoot $workspace -HomePath $root -ClaudeConfigPath $malformed | Out-Null
        throw 'FAIL: Malformed recognized MCP config did not fail closed'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Malformed recognized MCP config did not fail closed') { throw }
        Write-Output 'PASS: Malformed recognized MCP config fails closed'
    }
} finally {
    $env:XDG_CONFIG_HOME = $originalXdgConfigHome
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All registered MCP ownership tests passed.'
