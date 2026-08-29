[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'scripts\SteamVrHeadless.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru
$testRoot = Join-Path $env:TEMP ("steamvr-headless-tests-" + [Guid]::NewGuid().ToString('N'))
$originalGetSteamClientProcesses = $null
$currentSuite = $null

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $steamVrRoot = Join-Path $testRoot 'SteamLibrary\steamapps\common\SteamVR'
    $secondSteamVrRoot = Join-Path $testRoot 'SecondSteamLibrary\steamapps\common\SteamVR'
    New-FixtureSteamVrRuntime -Root $steamVrRoot
    New-FixtureSteamVrRuntime -Root $secondSteamVrRoot

    $originalGetSteamClientProcesses = & $module {
        (Get-Command Get-SteamClientProcesses -CommandType Function).ScriptBlock
    }
    & $module {
        param($SteamClient)
        $script:fixtureSteamClientProcesses = @($SteamClient)
        Set-Item -Path Function:script:Get-SteamClientProcesses -Value {
            @($script:fixtureSteamClientProcesses)
        }
    } (New-FixtureSteamClientRecord)

    $context = [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        Root = $testRoot
        Module = $module
        EntryScript = Join-Path $repositoryRoot 'scripts\steamvr-headless.ps1'
        SupervisorScript = Join-Path $repositoryRoot 'scripts\internal\SupervisorHost.ps1'
        SteamVrRoot = $steamVrRoot
        SecondSteamVrRoot = $secondSteamVrRoot
    }

    foreach ($suite in @(
        'HeadlessMode.ps1',
        'RuntimeOwnership.ps1',
        'RunState.ps1',
        'Lifecycle.ps1'
    )) {
        $currentSuite = $suite
        & (Join-Path $PSScriptRoot "suites\$suite") -Context $context
    }

    [pscustomobject]@{
        ok = $true
        passed = $global:SteamVrHeadlessPassedTests.Count
        tests = @($global:SteamVrHeadlessPassedTests)
    } | ConvertTo-Json -Depth 5
    exit 0
} catch {
    [pscustomobject]@{
        ok = $false
        passed = $global:SteamVrHeadlessPassedTests.Count
        tests = @($global:SteamVrHeadlessPassedTests)
        suite = $currentSuite
        error = $_.Exception.Message
        location = $_.InvocationInfo.PositionMessage
    } | ConvertTo-Json -Depth 5
    exit 1
} finally {
    if ($originalGetSteamClientProcesses) {
        & $module {
            param($Original)
            Set-Item -Path Function:script:Get-SteamClientProcesses -Value $Original
            Remove-Variable -Name fixtureSteamClientProcesses -Scope Script -ErrorAction SilentlyContinue
        } $originalGetSteamClientProcesses
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name SteamVrHeadlessPassedTests -Scope Global -ErrorAction SilentlyContinue
}
