[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'scripts\SteamVRNullDriver.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru
$testRoot = Join-Path $env:TEMP ("steamvr-null-driver-tests-" + [Guid]::NewGuid().ToString('N'))
$originalGetSteamClientProcesses = $null
$currentSuite = $null

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $steamVRRoot = Join-Path $testRoot 'SteamLibrary\steamapps\common\SteamVR'
    $secondSteamVRRoot = Join-Path $testRoot 'SecondSteamLibrary\steamapps\common\SteamVR'
    New-FixtureSteamVRRuntime -Root $steamVRRoot
    New-FixtureSteamVRRuntime -Root $secondSteamVRRoot

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
        EntryScript = Join-Path $repositoryRoot 'scripts\SteamVRNullDriver.ps1'
        SupervisorScript = Join-Path $repositoryRoot 'scripts\internal\SupervisorHost.ps1'
        SteamVRRoot = $steamVRRoot
        SecondSteamVRRoot = $secondSteamVRRoot
    }

    foreach ($suite in @(
        'NullDriverMode.ps1',
        'RuntimeOwnership.ps1',
        'RunState.ps1',
        'Lifecycle.ps1'
    )) {
        $currentSuite = $suite
        & (Join-Path $PSScriptRoot "suites\$suite") -Context $context
    }

    [pscustomobject]@{
        ok = $true
        passed = $global:SteamVRNullDriverPassedTests.Count
        tests = @($global:SteamVRNullDriverPassedTests)
    } | ConvertTo-Json -Depth 5
    exit 0
} catch {
    [pscustomobject]@{
        ok = $false
        passed = $global:SteamVRNullDriverPassedTests.Count
        tests = @($global:SteamVRNullDriverPassedTests)
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
    Remove-Variable -Name SteamVRNullDriverPassedTests -Scope Global -ErrorAction SilentlyContinue
}
