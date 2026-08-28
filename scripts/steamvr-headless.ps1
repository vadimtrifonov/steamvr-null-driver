[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('check', 'start', 'status', 'stop', 'recover', 'supervise')]
    [string]$Action,

    [string]$SteamRoot,
    [string]$SteamVrRoot,
    [string]$RunId,

    [ValidateRange(1, 1440)]
    [int]$MaxDurationMinutes = 30,

    [ValidateRange(15, 300)]
    [int]$StartupTimeoutSeconds = 90,

    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'SteamVrHeadless')
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'SteamVrHeadless.psm1'
Import-Module -Name $modulePath -Force

try {
    $result = switch ($Action) {
        'check' {
            Invoke-SteamVrHeadlessCheck `
                -SteamRoot $SteamRoot `
                -SteamVrRoot $SteamVrRoot `
                -StateRoot $StateRoot
        }
        'start' {
            Start-SteamVrHeadlessRun `
                -SteamRoot $SteamRoot `
                -SteamVrRoot $SteamVrRoot `
                -StateRoot $StateRoot `
                -EntryScriptPath $PSCommandPath `
                -MaxDurationMinutes $MaxDurationMinutes `
                -StartupTimeoutSeconds $StartupTimeoutSeconds
        }
        'status' {
            Get-SteamVrHeadlessStatus -RunId $RunId -StateRoot $StateRoot
        }
        'stop' {
            Stop-SteamVrHeadlessRun -RunId $RunId -StateRoot $StateRoot
        }
        'recover' {
            Invoke-SteamVrHeadlessRecovery -StateRoot $StateRoot
        }
        'supervise' {
            if (-not $RunId) {
                throw 'The internal supervise action requires -RunId.'
            }
            Invoke-SteamVrHeadlessSupervisor -RunId $RunId -StateRoot $StateRoot
            exit 0
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
