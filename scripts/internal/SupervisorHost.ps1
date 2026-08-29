[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$StateRoot
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'SteamVRNullDriver.psm1'
Import-Module -Name $modulePath -Force
Invoke-SteamVRNullDriverSupervisor -RunId $RunId -StateRoot $StateRoot
