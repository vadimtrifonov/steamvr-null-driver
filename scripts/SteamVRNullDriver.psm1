Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:StartupTimeoutSeconds = 90
$script:StopTimeoutSeconds = 90

foreach ($file in @(
    'Common.ps1',
    'Configuration.ps1',
    'Log.ps1',
    'Runtime.ps1',
    'State.ps1',
    'Cleanup.ps1',
    'Supervisor.ps1',
    'Commands.ps1'
)) {
    . (Join-Path $PSScriptRoot "internal\$file")
}

Export-ModuleMember -Function @(
    'Invoke-SteamVRNullDriverCheck',
    'Start-SteamVRNullDriverRun',
    'Get-SteamVRNullDriverStatus',
    'Stop-SteamVRNullDriverRun',
    'Invoke-SteamVRNullDriverSupervisor'
)
