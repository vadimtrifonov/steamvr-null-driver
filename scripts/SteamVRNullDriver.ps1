[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('check', 'start', 'status', 'stop')]
    [string]$Action,

    [string]$SteamVRRoot,
    [string]$RunId,

    [ValidateRange(1, 120)]
    [int]$MaxDurationMinutes = 30
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'SteamVRNullDriver.psm1'
Import-Module -Name $modulePath -Force

try {
    $stateRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'SteamVRNullDriver'))
    $result = switch ($Action) {
        'check' {
            Invoke-SteamVRNullDriverCheck -SteamVRRoot $SteamVRRoot -StateRoot $stateRoot
        }
        'start' {
            Start-SteamVRNullDriverRun `
                -SteamVRRoot $SteamVRRoot `
                -StateRoot $stateRoot `
                -SupervisorScriptPath (Join-Path $PSScriptRoot 'internal\SupervisorHost.ps1') `
                -MaxDurationMinutes $MaxDurationMinutes
        }
        'status' {
            if (-not $RunId) { throw 'status requires -RunId.' }
            Get-SteamVRNullDriverStatus -RunId $RunId -StateRoot $stateRoot
        }
        'stop' {
            if (-not $RunId) { throw 'stop requires -RunId.' }
            Stop-SteamVRNullDriverRun -RunId $RunId -StateRoot $stateRoot
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
