[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$StateRoot
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'SteamVrHeadless.psm1'
Import-Module -Name $modulePath -Force
Invoke-SteamVrHeadlessSupervisor -RunId $RunId -StateRoot $StateRoot
