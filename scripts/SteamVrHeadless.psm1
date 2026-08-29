Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($file in @(
    'Common.ps1',
    'Configuration.ps1',
    'Log.ps1',
    'Runtime.ps1',
    'Journal.ps1',
    'Cleanup.ps1',
    'Commands.ps1',
    'Supervisor.ps1'
)) {
    . (Join-Path $PSScriptRoot "internal\$file")
}

Export-ModuleMember -Function @(
    'Invoke-SteamVrHeadlessCheck',
    'Start-SteamVrHeadlessRun',
    'Get-SteamVrHeadlessStatus',
    'Stop-SteamVrHeadlessRun',
    'Invoke-SteamVrHeadlessSupervisor'
)
