[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('check', 'start', 'status', 'stop')]
    [string]$Action,

    [string]$SteamVrRoot,
    [string]$RunId,

    [ValidateRange(1, 120)]
    [int]$MaxDurationMinutes = 30
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'SteamVrHeadless.psm1'
Import-Module -Name $modulePath -Force

try {
    $stateRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'SteamVrHeadless'))
    $result = switch ($Action) {
        'check' {
            Invoke-SteamVrHeadlessCheck -SteamVrRoot $SteamVrRoot -StateRoot $stateRoot
        }
        'start' {
            Start-SteamVrHeadlessRun `
                -SteamVrRoot $SteamVrRoot `
                -StateRoot $stateRoot `
                -SupervisorScriptPath (Join-Path $PSScriptRoot 'internal\SupervisorHost.ps1') `
                -MaxDurationMinutes $MaxDurationMinutes
        }
        'status' {
            Get-SteamVrHeadlessStatus -RunId $RunId -StateRoot $stateRoot
        }
        'stop' {
            Stop-SteamVrHeadlessRun -RunId $RunId -StateRoot $stateRoot
        }
    }

    $result | ConvertTo-Json -Depth 20 -Compress
    if ($null -ne $result.PSObject.Properties['ok'] -and -not [bool]$result.ok) {
        exit 1
    }
    exit 0
} catch {
    [pscustomobject]@{
        ok = $false
        action = $Action
        runId = $RunId
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 10 -Compress
    exit 1
}
