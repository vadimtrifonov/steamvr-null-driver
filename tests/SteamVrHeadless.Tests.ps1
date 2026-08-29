[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\SteamVrHeadless.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru
$entryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\steamvr-headless.ps1'
$supervisorScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\internal\SupervisorHost.ps1'
$testRoot = Join-Path $env:TEMP ("steamvr-headless-tests-" + [Guid]::NewGuid().ToString('N'))
$passed = [System.Collections.Generic.List[string]]::new()
$originalGetSteamClientProcesses = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Complete-Test {
    param([string]$Name)
    $passed.Add($Name)
}

function New-FixtureRunConfiguration {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$SteamVrRoot,
        [DateTime]$CreatedUtc = [DateTime]::UtcNow,
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMinutes(10)
    )

    [pscustomobject][ordered]@{
        schemaVersion = 5
        runId = $RunId
        createdUtc = $CreatedUtc.ToString('o')
        deadlineUtc = $DeadlineUtc.ToString('o')
        steamVrRoot = $SteamVrRoot
    }
}

function Write-FixtureRunConfiguration {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Configuration
    )

    $Configuration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Encoding utf8NoBOM
    & $module { param($Run) Read-RunConfiguration -RunDirectory $Run } $RunDirectory
}

function New-FixtureSteamVrRuntime {
    param([Parameter(Mandatory)][string]$Root)

    foreach ($relativePath in @(
        'bin\win64\vrstartup.exe',
        'bin\win64\vrserver.exe',
        'bin\win64\vrcompositor.exe',
        'bin\win64\vrmonitor.exe',
        'drivers\null\bin\win64\driver_null.dll'
    )) {
        $path = Join-Path $Root $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, '')
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $originalGetSteamClientProcesses = & $module { (Get-Command Get-SteamClientProcesses -CommandType Function).ScriptBlock }
    & $module {
        $script:fixtureSteamClientProcesses = @([pscustomobject]@{
            pid = 1
            name = 'steam'
            path = 'C:\FixtureSteam\steam.exe'
            creationUtc = '2026-01-01T00:00:00Z'
        })
        Set-Item -Path Function:script:Get-SteamClientProcesses -Value { @($script:fixtureSteamClientProcesses) }
    }

    $headlessText = & $module { Get-HeadlessSettingsText }
    $headless = $headlessText | ConvertFrom-Json
    Assert-Equal @($headless.PSObject.Properties).Count 4 'The generated settings contain an unexpected top-level section.'
    Assert-Equal $headless.steamvr.requireHmd $false 'requireHmd was not disabled.'
    Assert-Equal $headless.steamvr.forcedDriver 'null' 'The null driver was not forced.'
    Assert-Equal $headless.steamvr.activateMultipleDrivers $false 'Multiple drivers were not disabled.'
    Assert-Equal $headless.steamvr.startDashboardFromAppLaunch $false 'Dashboard startup was not disabled.'
    Assert-Equal $headless.steamvr.startOverlayAppsFromDashboard $false 'Dashboard overlay startup was not disabled.'
    Assert-Equal $headless.steamvr.enableHomeApp $false 'SteamVR Home was not disabled.'
    Assert-Equal $headless.driver_null.enable $true 'The null driver was not enabled.'
    Assert-Equal $headless.dashboard.enableDashboard $false 'The dashboard was not disabled.'
    Assert-Equal $headless.direct_mode.enable $false 'Direct Display Mode was not disabled.'
    foreach ($section in @('LastKnown', 'audio', 'collisionBounds')) {
        Assert-True ($null -eq $headless.PSObject.Properties[$section]) "The generated settings contain '$section'."
    }
    Complete-Test 'minimal headless settings generation'

    $futureUtc = [DateTime]::UtcNow.AddMinutes(10)
    $deserializedUtc = ([pscustomobject]@{ value=$futureUtc.ToString('o') } | ConvertTo-Json | ConvertFrom-Json).value
    $convertedUtc = & $module { param($Value) ConvertTo-UtcDateTime $Value } $deserializedUtc
    Assert-True ([Math]::Abs(($convertedUtc - $futureUtc).TotalMilliseconds) -lt 1) 'A deserialized UTC timestamp changed during conversion.'
    Assert-True ($convertedUtc -gt [DateTime]::UtcNow) 'A future UTC deadline became expired during conversion.'
    Complete-Test 'UTC timestamp conversion'

    $missingParent = Join-Path $testRoot 'missing-json-parent'
    $atomicWriteFailed = $false
    try {
        & $module {
            param($Path)
            Write-JsonAtomic -Path $Path -Value ([pscustomobject]@{ value='test' })
        } (Join-Path $missingParent 'state.json')
    } catch {
        $atomicWriteFailed = $true
    }
    Assert-True $atomicWriteFailed 'An atomic state write created a missing run directory.'
    Assert-True (-not (Test-Path -LiteralPath $missingParent)) 'An atomic state write recreated a deleted run directory.'
    Complete-Test 'atomic state writes require an existing run directory'

    $chaperone = (& $module { Get-TemporaryChaperoneText }) | ConvertFrom-Json
    Assert-Equal $chaperone.jsonid 'chaperone_info' 'The temporary chaperone identifier is invalid.'
    Assert-Equal $chaperone.version 5 'The temporary chaperone version is invalid.'
    Assert-Equal $chaperone.universes[0].universeID 2 'The temporary chaperone universe does not match the null driver.'
    Assert-True ($chaperone.universes[0].universeID -isnot [string]) 'The chaperone universe ID is a string.'
    Assert-True ($null -ne $chaperone.universes[0].seated) 'The placeholder calibration has no seated transform.'
    Assert-True ($null -ne $chaperone.universes[0].standing) 'The placeholder calibration has no standing transform.'
    Complete-Test 'temporary chaperone schema'

    $nullLog = @'
Loaded server driver null (IServerTrackedDeviceProvider_004) from C:\SteamVR\driver_null.dll
Driver 'null' started activation of tracked device with serial number 'Null Serial Number'
Active HMD set to null.Null Serial Number
'@
    $assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $nullLog
    Assert-True $assessment.ready 'A null-only runtime was not accepted.'
    Assert-Equal $assessment.unexpectedDrivers.Count 0 'The null driver was classified as unexpected.'
    Complete-Test 'null-only log assessment'

    $futureDriverLog = @'
Loaded server driver null (IServerTrackedDeviceProvider_004) from C:\SteamVR\driver_null.dll
Active HMD set to null.Null Serial Number
Loaded server driver tomorrow_headset (IServerTrackedDeviceProvider_004) from C:\Future\driver.dll
Active HMD set to tomorrow_headset.Serial 1
'@
    $assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $futureDriverLog
    Assert-True $assessment.modeViolation 'An unknown future driver did not cause a mode violation.'
    Assert-True ($assessment.unexpectedDrivers -contains 'tomorrow_headset') 'The unknown driver was not reported.'
    Assert-True (-not $assessment.ready) 'An unexpected HMD mode was accepted.'
    Complete-Test 'generic unexpected-driver rejection'

    $roomSetupLog = $nullLog + "`nStarting process C:\SteamVR\tools\steamvr_room_setup.exe as app openvr.tool.steamvr_room_setup"
    $assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $roomSetupLog
    Assert-True $assessment.roomSetupDetected 'Room Setup was not detected.'
    Assert-True (-not $assessment.ready) 'A runtime with Room Setup was accepted.'
    Complete-Test 'Room Setup rejection'

    $directModeLog = $nullLog + "`n[Display] Enabling direct mode for NVIDIA [Vid=0x0000 Pid=0x0000]..."
    $assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $directModeLog
    Assert-True $assessment.directModeDetected 'Direct Display Mode activation was not detected.'
    Assert-True $assessment.modeViolation 'Direct Display Mode did not cause a mode violation.'
    Assert-True (-not $assessment.ready) 'A runtime that enabled Direct Display Mode was accepted.'
    Complete-Test 'Direct Display Mode rejection'

    $privateLogPath = Join-Path $testRoot 'private-vrserver.log'
    $missingLogText = & $module { param($Path) Read-VrLogText -Path $Path } $privateLogPath
    Assert-Equal $missingLogText '' 'A missing private log did not read as empty.'
    [System.IO.File]::WriteAllText($privateLogPath, $nullLog)
    $sharedLogText = & $module { param($Path) Read-VrLogText -Path $Path } $privateLogPath
    $sharedLogAssessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $sharedLogText
    Assert-True $sharedLogAssessment.ready 'The private log reader did not return the complete startup log.'
    Complete-Test 'private log shared reader'

    $fakeRuntime = Join-Path $testRoot 'SteamLibrary\steamapps\common\SteamVR'
    $secondRuntime = Join-Path $testRoot 'SecondSteamLibrary\steamapps\common\SteamVR'
    New-FixtureSteamVrRuntime -Root $fakeRuntime
    New-FixtureSteamVrRuntime -Root $secondRuntime
    $discovery = & $module {
        param($FixtureRuntime, $FixtureSecondRuntime)
        $originalSteamVrRoots = (Get-Command Get-RegisteredSteamVrRoots -CommandType Function).ScriptBlock
        $script:fixtureSteamVrRoots = @($FixtureRuntime)
        Set-Item -Path Function:Get-RegisteredSteamVrRoots -Value { @($script:fixtureSteamVrRoots) }
        try {
            $registered = Resolve-SteamVrRoot
            $explicit = Resolve-SteamVrRoot -SteamVrRoot $FixtureRuntime
            $script:fixtureSteamVrRoots = @($FixtureRuntime, $FixtureSecondRuntime)
            $ambiguousRejected = $false
            try { $null = Resolve-SteamVrRoot } catch { $ambiguousRejected = $true }
            [pscustomobject]@{ registered=$registered;explicit=$explicit;ambiguousRejected=$ambiguousRejected }
        } finally {
            Set-Item -Path Function:Get-RegisteredSteamVrRoots -Value $originalSteamVrRoots
            Remove-Variable -Name fixtureSteamVrRoots -Scope Script -ErrorAction SilentlyContinue
        }
    } $fakeRuntime $secondRuntime
    Assert-Equal $discovery.registered ([IO.Path]::GetFullPath($fakeRuntime)) 'Automatic discovery did not use Steam App 250820 registration.'
    Complete-Test 'automatic registered SteamVR discovery'
    Assert-Equal $discovery.explicit ([IO.Path]::GetFullPath($fakeRuntime)) 'Explicit SteamVR discovery changed the runtime root.'
    Complete-Test 'explicit SteamVR root discovery'
    Assert-True $discovery.ambiguousRejected 'Automatic discovery selected one of multiple registered SteamVR installations.'
    Complete-Test 'ambiguous SteamVR discovery is refused'

    $incompleteRuntime = Join-Path $testRoot 'IncompleteSteamVR'
    New-Item -ItemType Directory -Path (Join-Path $incompleteRuntime 'bin\win64') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $incompleteRuntime 'bin\win64\vrstartup.exe'), '')
    $incompleteRejected = $false
    try { $null = & $module { param($Root) Resolve-SteamVrRoot -SteamVrRoot $Root } $incompleteRuntime } catch { $incompleteRejected = $true }
    Assert-True $incompleteRejected 'An incomplete SteamVR root was accepted.'
    Complete-Test 'incomplete SteamVR root rejection'

    $cleanupOnlyRuntime = Join-Path $testRoot 'CleanupOnlySteamVR'
    foreach ($relativePath in @(
        'bin\win64\vrserver.exe',
        'bin\win64\vrcompositor.exe',
        'bin\win64\vrmonitor.exe'
    )) {
        $path = Join-Path $cleanupOnlyRuntime $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, '')
    }
    $cleanupShape = & $module {
        param($Root)
        Assert-SteamVrCleanupLayout -SteamVrRoot $Root
        $launchAccepted = $true
        try { Assert-SteamVrRuntimeLayout -SteamVrRoot $Root } catch { $launchAccepted = $false }
        [pscustomobject]@{ launchAccepted=$launchAccepted }
    } $cleanupOnlyRuntime
    Assert-True (-not $cleanupShape.launchAccepted) 'A cleanup-only root was accepted for startup without its startup executable and null driver.'
    Complete-Test 'launch and cleanup layouts are separate'

    $privateFixtureRoot = Join-Path $testRoot 'private-fixture'
    $privateConfig = Join-Path $privateFixtureRoot 'config'
    $privateLogs = Join-Path $privateFixtureRoot 'logs'
    & $module {
        param($Config, $Logs)
        Initialize-PrivateHeadlessConfiguration -PrivateConfigRoot $Config -PrivateLogRoot $Logs
    } $privateConfig $privateLogs
    $privateSettings = Get-Content -LiteralPath (Join-Path $privateConfig 'steamvr.vrsettings') -Raw | ConvertFrom-Json
    Assert-Equal $privateSettings.steamvr.forcedDriver 'null' 'The private settings did not force the null driver.'
    Assert-Equal @($privateSettings.PSObject.Properties).Count 4 'Private initialization wrote non-minimal settings.'
    Assert-Equal $privateSettings.direct_mode.enable $false 'Private initialization did not disable Direct Display Mode.'
    Assert-True (Test-Path -LiteralPath (Join-Path $privateConfig 'chaperone_info.vrchap')) 'Private configuration has no chaperone data.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $privateConfig 'appconfig.json'))) 'Private initialization created application metadata before SteamVR ran.'
    Assert-True (Test-Path -LiteralPath $privateLogs -PathType Container) 'Private configuration did not create its log directory.'
    Complete-Test 'private configuration is generated from constants'

    $processInfo = & $module {
        param($Path, $Runtime, $Config, $Logs)
        New-OpenVrProcessInfo -Path $Path -SteamVrRoot $Runtime -PrivateConfigRoot $Config -PrivateLogRoot $Logs
    } (Join-Path $fakeRuntime 'bin\win64\vrstartup.exe') $fakeRuntime $privateConfig $privateLogs
    Assert-Equal $processInfo.Environment['VR_OVERRIDE'] ([IO.Path]::GetFullPath($fakeRuntime)) 'VR_OVERRIDE does not use the selected SteamVR runtime.'
    Assert-Equal $processInfo.Environment['VR_CONFIG_PATH'] ([IO.Path]::GetFullPath($privateConfig)) 'VR_CONFIG_PATH does not use the private config.'
    Assert-Equal $processInfo.Environment['VR_LOG_PATH'] ([IO.Path]::GetFullPath($privateLogs)) 'VR_LOG_PATH does not use the private logs.'
    Complete-Test 'startup environment uses private paths'

    $journalRunId = [Guid]::NewGuid().ToString('N')
    $journalRun = Join-Path (Join-Path $testRoot 'journal-runs') $journalRunId
    New-Item -ItemType Directory -Path $journalRun -Force | Out-Null
    $storedJournalConfiguration = New-FixtureRunConfiguration -RunId $journalRunId -SteamVrRoot $fakeRuntime
    $journalConfiguration = Write-FixtureRunConfiguration -RunDirectory $journalRun -Configuration $storedJournalConfiguration
    Assert-True ($null -eq $storedJournalConfiguration.PSObject.Properties['steamRoot']) 'The stored journal contains an unused Steam root.'
    Assert-True ($null -eq $storedJournalConfiguration.PSObject.Properties['startupTimeoutSeconds']) 'The stored journal contains a fixed startup timeout.'
    Assert-True ($null -eq $storedJournalConfiguration.PSObject.Properties['privateConfigRoot']) 'The stored journal contains a derived private config path.'
    Assert-True ($null -eq $storedJournalConfiguration.PSObject.Properties['vrStartupPath']) 'The stored journal contains a derived startup path.'
    Assert-Equal $journalConfiguration.privateConfigRoot ([IO.Path]::GetFullPath((Join-Path $journalRun 'config'))) 'The journal did not derive its private config path.'
    Assert-Equal $journalConfiguration.privateLogRoot ([IO.Path]::GetFullPath((Join-Path $journalRun 'logs'))) 'The journal did not derive its private log path.'
    Assert-Equal $journalConfiguration.vrStartupPath ([IO.Path]::GetFullPath((Join-Path $fakeRuntime 'bin\win64\vrstartup.exe'))) 'The journal did not derive its startup path.'
    Complete-Test 'run configuration derives private paths'

    $unsafeRunId = [Guid]::NewGuid().ToString('N')
    $unsafeStateRoot = Join-Path $testRoot 'unsafe-journal-state'
    $unsafeRun = Join-Path (Join-Path $unsafeStateRoot 'runs') $unsafeRunId
    New-Item -ItemType Directory -Path $unsafeRun -Force | Out-Null
    $unsafeStoredConfiguration = New-FixtureRunConfiguration -RunId $unsafeRunId -SteamVrRoot $incompleteRuntime
    $unsafeConfiguration = Write-FixtureRunConfiguration -RunDirectory $unsafeRun -Configuration $unsafeStoredConfiguration
    [pscustomobject]@{ runId=$unsafeRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $unsafeStateRoot 'active-run.json') -Encoding utf8NoBOM
    $unsafeCleanup = & $module {
        param($RunDirectory, $StateRoot, $Configuration)
        Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
    } $unsafeRun $unsafeStateRoot $unsafeConfiguration
    Assert-True (-not $unsafeCleanup.complete) 'Cleanup accepted an unrecognizable destructive runtime root.'
    Assert-True (Test-Path -LiteralPath (Join-Path $unsafeStateRoot 'active-run.json')) 'Cleanup removed the lock for an unrecognizable runtime root.'
    Complete-Test 'cleanup runtime root validation'

    $entryCommand = Get-Command $entryScript
    foreach ($removedParameter in @('SteamRoot', 'StateRoot', 'StartupTimeoutSeconds')) {
        Assert-True (-not $entryCommand.Parameters.ContainsKey($removedParameter)) "The public CLI still exposes -$removedParameter."
    }
    $actionValues = @($entryCommand.Parameters['Action'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } | Select-Object -ExpandProperty ValidValues)
    Assert-Equal (($actionValues | Sort-Object) -join ',') 'check,start,status,stop' 'The public CLI action set is not minimal.'
    foreach ($commandName in @('Get-SteamVrHeadlessStatus', 'Stop-SteamVrHeadlessRun')) {
        $runIdParameter = (Get-Command -Module $module.Name $commandName).Parameters['RunId']
        $parameterAttribute = @($runIdParameter.Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] })[0]
        Assert-True $parameterAttribute.Mandatory "$commandName does not require a run ID."
    }
    Complete-Test 'narrow public CLI parameters'

    $stateRoot = Join-Path $testRoot 'state'
    $check = Invoke-SteamVrHeadlessCheck -SteamVrRoot $fakeRuntime -StateRoot $stateRoot
    Assert-True $check.ok 'The read-only check failed for valid fixture paths.'
    Assert-True $check.canStart 'The read-only check rejected an idle valid fixture.'
    Assert-Equal $check.steamVrRoot ([IO.Path]::GetFullPath($fakeRuntime)) 'The read-only check did not return the selected runtime root.'
    Assert-True ($null -eq $check.PSObject.Properties['paths']) 'The read-only check returned an unnecessary paths wrapper.'
    Assert-Equal $check.steamProcesses.Count 1 'The read-only check did not report the Steam client.'
    Assert-True ($null -eq $check.PSObject.Properties['invariant']) 'The read-only check returned duplicated invariant metadata.'
    Complete-Test 'Steam client prerequisite is visible'

    & $module { $script:fixtureSteamClientProcesses = @() }
    $withoutSteam = Invoke-SteamVrHeadlessCheck -SteamVrRoot $fakeRuntime -StateRoot $stateRoot
    Assert-True $withoutSteam.ok 'A missing Steam client made check itself fail.'
    Assert-True (-not $withoutSteam.canStart) 'A missing Steam client was accepted for startup.'
    & $module {
        $script:fixtureSteamClientProcesses = @([pscustomobject]@{
            pid = 1
            name = 'steam'
            path = 'C:\FixtureSteam\steam.exe'
            creationUtc = '2026-01-01T00:00:00Z'
        })
    }
    Complete-Test 'Steam client is required in the interactive session'

    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $lockRunId = [Guid]::NewGuid().ToString('N')
    [pscustomobject]@{ runId=$lockRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'active-run.json') -Encoding utf8NoBOM
    $check = Invoke-SteamVrHeadlessCheck -SteamVrRoot $fakeRuntime -StateRoot $stateRoot
    Assert-True $check.ok 'The read-only check could not inspect a valid active-run lock.'
    Assert-True (-not $check.canStart) 'The read-only check ignored an active-run lock.'
    Remove-Item -LiteralPath (Join-Path $stateRoot 'active-run.json') -Force
    $inactiveDirectory = Join-Path (Join-Path $stateRoot 'runs') 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    New-Item -ItemType Directory -Path $inactiveDirectory -Force | Out-Null
    '{"phase":"expired","updatedUtc":"2026-01-01T00:00:00Z"}' | Set-Content -LiteralPath (Join-Path $inactiveDirectory 'status.json') -Encoding utf8NoBOM
    $check = Invoke-SteamVrHeadlessCheck -SteamVrRoot $fakeRuntime -StateRoot $stateRoot
    Assert-True $check.canStart 'An inactive private journal blocked an otherwise safe start.'
    Assert-Equal $check.inactiveRuns.Count 1 'The read-only check did not report the inactive journal.'
    Assert-Equal $check.inactiveRuns[0].phase 'expired' 'The read-only check lost the inactive journal phase.'
    Complete-Test 'retained runs are visible but do not block preflight'

    $victimDirectory = Join-Path $stateRoot 'victim'
    New-Item -ItemType Directory -Path $victimDirectory -Force | Out-Null
    'keep' | Set-Content -LiteralPath (Join-Path $victimDirectory 'marker.txt') -Encoding utf8NoBOM
    $traversalOutput = Stop-SteamVrHeadlessRun -RunId '..\victim' -StateRoot $stateRoot
    Assert-True (-not $traversalOutput.ok) 'A path-like run ID was accepted.'
    Assert-True (Test-Path -LiteralPath (Join-Path $victimDirectory 'marker.txt')) 'A path-like run ID escaped the runs directory.'
    Complete-Test 'run ID path boundary'

    $loserState = Join-Path $testRoot 'lock-loser-state'
    $loserResult = & $module {
        param($SteamVrRoot, $StateRoot, $SupervisorScript)
        $script:loserCleanupCalled = $false
        $originalNewActiveRunRecord = (Get-Command New-ActiveRunRecord -CommandType Function).ScriptBlock
        $originalInvokeRunCleanup = (Get-Command Invoke-RunCleanup -CommandType Function).ScriptBlock
        Set-Item -Path Function:New-ActiveRunRecord -Value { throw 'injected competing lock owner' }
        Set-Item -Path Function:Invoke-RunCleanup -Value {
            $script:loserCleanupCalled = $true
            throw 'destructive cleanup was called'
        }
        try {
            $startResult = Start-SteamVrHeadlessRun -SteamVrRoot $SteamVrRoot -StateRoot $StateRoot -SupervisorScriptPath $SupervisorScript
            [pscustomobject]@{ start=$startResult;cleanupCalled=$script:loserCleanupCalled }
        } finally {
            Set-Item -Path Function:New-ActiveRunRecord -Value $originalNewActiveRunRecord
            Set-Item -Path Function:Invoke-RunCleanup -Value $originalInvokeRunCleanup
            Remove-Variable -Name loserCleanupCalled -Scope Script -ErrorAction SilentlyContinue
        }
    } $fakeRuntime $loserState $supervisorScript
    Assert-True (-not $loserResult.start.ok) 'A start that lost the active lock reported success.'
    Assert-True (-not $loserResult.cleanupCalled) 'A start that lost the active lock invoked destructive cleanup.'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $loserState 'runs') -Directory -ErrorAction SilentlyContinue).Count) 0 'A start that lost the active lock retained its run directory.'
    Complete-Test 'competing start loser is non-destructive'

    $inspectionRecord = & $module { Get-CurrentProcessRecord }
    $inspectionResult = & $module {
        param($SteamVrRoot, $StateRoot, $Record)
        Set-Item -Path Function:Get-CimInstance -Value { throw 'injected process query failure' }
        try {
            $failedCheck = Invoke-SteamVrHeadlessCheck -SteamVrRoot $SteamVrRoot -StateRoot $StateRoot
            $identityQueryFailed = $false
            try {
                $null = Get-SupervisorAlive -Supervisor $Record
            } catch {
                $identityQueryFailed = $true
            }
            [pscustomobject]@{ checkOk=$failedCheck.ok;identityQueryFailed=$identityQueryFailed }
        } finally {
            Remove-Item -Path Function:Get-CimInstance -Force
        }
    } $fakeRuntime (Join-Path $testRoot 'query-failure-state') $inspectionRecord
    Assert-True (-not $inspectionResult.checkOk) 'A failed process enumeration looked like an idle runtime.'
    Assert-True $inspectionResult.identityQueryFailed 'A failed identity query looked like a dead supervisor.'
    Complete-Test 'process inspection fails closed'

    $unreadableResult = & $module {
        param($RuntimeRoot)
        Set-Item -Path Function:Get-CimInstance -Value {
            param($ClassName, $Filter, $ErrorAction)
            [pscustomobject]@{ ProcessId=42;Name='vrserver.exe';ExecutablePath=$null;CreationDate=[DateTime]::UtcNow }
        }
        try {
            try {
                $null = Get-SteamVrRuntimeProcesses -SteamVrRoot $RuntimeRoot
                [pscustomobject]@{ failed=$false;error=$null }
            } catch {
                [pscustomobject]@{ failed=$true;error=$_.Exception.Message }
            }
        } finally {
            Remove-Item -Path Function:Get-CimInstance -Force
        }
    } $fakeRuntime
    Assert-True $unreadableResult.failed 'An unreadable vrserver process looked like an idle runtime.'
    Assert-True ($unreadableResult.error -match 'no readable executable path') 'The unreadable process error did not identify the missing path.'
    Complete-Test 'unreadable canonical process fails closed'

    $transientCount = & $module {
        param($RuntimeRoot)
        Set-Item -Path Function:Get-CimInstance -Value {
            param($ClassName, $Filter, $ErrorAction)
            if ($Filter) {
                return $null
            }
            [pscustomobject]@{ ProcessId=42;Name='vrmonitor.exe';ExecutablePath=$null;CreationDate=[DateTime]::UtcNow }
        }
        try {
            @(Get-SteamVrRuntimeProcesses -SteamVrRoot $RuntimeRoot).Count
        } finally {
            Remove-Item -Path Function:Get-CimInstance -Force
        }
    } $fakeRuntime
    Assert-Equal $transientCount 0 'An exited transient vrmonitor process caused an inspection failure.'
    Complete-Test 'exited unreadable canonical process is ignored'

    $ownershipState = Join-Path $testRoot 'ownership-state'
    $ownershipRunId = [Guid]::NewGuid().ToString('N')
    $otherRunId = [Guid]::NewGuid().ToString('N')
    $ownershipRun = Join-Path (Join-Path $ownershipState 'runs') $ownershipRunId
    $otherRun = Join-Path (Join-Path $ownershipState 'runs') $otherRunId
    New-Item -ItemType Directory -Path $ownershipRun, $otherRun -Force | Out-Null
    $storedOwnershipConfiguration = New-FixtureRunConfiguration -RunId $ownershipRunId -SteamVrRoot $fakeRuntime -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $ownershipConfiguration = Write-FixtureRunConfiguration -RunDirectory $ownershipRun -Configuration $storedOwnershipConfiguration
    New-Item -ItemType Directory -Path $ownershipConfiguration.privateConfigRoot -Force | Out-Null
    $ownershipMarker = Join-Path $ownershipConfiguration.privateConfigRoot 'marker.txt'
    [System.IO.File]::WriteAllText($ownershipMarker, 'retain')
    [pscustomobject]@{ runId=$otherRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ownershipState 'active-run.json') -Encoding utf8NoBOM
    $ownershipCleanup = & $module { param($RunDirectory, $StateRoot, $Configuration) Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration } $ownershipRun $ownershipState $ownershipConfiguration
    Assert-True (-not $ownershipCleanup.complete) 'Cleanup completed without owning the active lock.'
    Assert-True ($ownershipCleanup.error -match 'active lock') 'Cleanup did not report the ownership error.'
    Assert-True (Test-Path -LiteralPath $ownershipMarker) 'Cleanup removed private state that belonged to another run.'
    $ownershipActive = Get-Content -Raw -LiteralPath (Join-Path $ownershipState 'active-run.json') | ConvertFrom-Json
    Assert-Equal $ownershipActive.runId $otherRunId 'Cleanup changed another run active lock.'
    Complete-Test 'cleanup requires exact active lock'

    $orderState = Join-Path $testRoot 'cleanup-order-state'
    $orderRunId = [Guid]::NewGuid().ToString('N')
    $orderRun = Join-Path (Join-Path $orderState 'runs') $orderRunId
    New-Item -ItemType Directory -Path $orderRun -Force | Out-Null
    $storedOrderConfiguration = New-FixtureRunConfiguration -RunId $orderRunId -SteamVrRoot $fakeRuntime -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $orderConfiguration = Write-FixtureRunConfiguration -RunDirectory $orderRun -Configuration $storedOrderConfiguration
    [pscustomobject]@{ runId=$orderRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $orderState 'active-run.json') -Encoding utf8NoBOM
    $originalStopSteamVrRuntime = & $module { (Get-Command Stop-SteamVrRuntime -CommandType Function).ScriptBlock }
    & $module {
        Set-Item -Path Function:script:Stop-SteamVrRuntime -Value {
            param($SteamVrRoot, $PrivateConfigRoot, $PrivateLogRoot)
            [pscustomobject]@{ graceful=@();forced=@();errors=@();remaining=@([pscustomobject]@{pid=1;name='vrserver'});verifiedStopped=$false;privateConfigRoot=$PrivateConfigRoot;privateLogRoot=$PrivateLogRoot }
        }
    }
    try {
        $orderCleanup = & $module { param($RunDirectory, $StateRoot, $Configuration) Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration } $orderRun $orderState $orderConfiguration
        Assert-True (-not $orderCleanup.complete) 'Cleanup completed while a runtime process remained.'
        Assert-Equal $orderCleanup.processStops.privateConfigRoot $orderConfiguration.privateConfigRoot 'Cleanup did not use the private config for the quit process.'
        Assert-Equal $orderCleanup.processStops.privateLogRoot $orderConfiguration.privateLogRoot 'Cleanup did not use the private logs for the quit process.'
        Assert-True (Test-Path -LiteralPath (Join-Path $orderState 'active-run.json')) 'Cleanup removed the lock while a runtime process remained.'
    } finally {
        & $module { param($Original) Set-Item -Path Function:script:Stop-SteamVrRuntime -Value $Original } $originalStopSteamVrRuntime
    }
    Complete-Test 'runtime stops before lock removal'

    $activeStatusState = Join-Path $testRoot 'active-status-state'
    $activeStatusRunId = [Guid]::NewGuid().ToString('N')
    $activeStatusRun = Join-Path (Join-Path $activeStatusState 'runs') $activeStatusRunId
    New-Item -ItemType Directory -Path $activeStatusRun -Force | Out-Null
    $activeStatusConfiguration = Write-FixtureRunConfiguration `
        -RunDirectory $activeStatusRun `
        -Configuration (New-FixtureRunConfiguration -RunId $activeStatusRunId -SteamVrRoot $fakeRuntime)
    [pscustomobject]@{ runId=$activeStatusRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $activeStatusState 'active-run.json') -Encoding utf8NoBOM
    $activeStatusSupervisor = & $module { Get-CurrentProcessRecord }
    [pscustomobject]@{
        runId = $activeStatusRunId
        phase = 'ready'
        supervisor = $activeStatusSupervisor
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $activeStatusRun 'status.json') -Encoding utf8NoBOM
    $activeStatus = Get-SteamVrHeadlessStatus -RunId $activeStatusRunId -StateRoot $activeStatusState
    Assert-True $activeStatus.ok 'Status could not inspect active run state.'
    Assert-True $activeStatus.active 'Status did not report exact active-lock ownership.'
    Assert-True $activeStatus.supervisorAlive 'Status did not find the self-registered supervisor.'
    Assert-Equal $activeStatus.runtimeProcesses.Count 0 'Status reported unexpected active runtime processes.'
    $activeStatusCleanup = & $module {
        param($RunDirectory, $StateRoot, $Configuration)
        Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
    } $activeStatusRun $activeStatusState $activeStatusConfiguration
    Assert-True $activeStatusCleanup.complete 'The active status fixture did not clean successfully.'
    Remove-Item -LiteralPath $activeStatusState -Recurse -Force
    Complete-Test 'status separates active observation from retained state'

    $contradictoryState = Join-Path $testRoot 'contradictory-terminal-state'
    $contradictoryRunId = [Guid]::NewGuid().ToString('N')
    $contradictoryRun = Join-Path (Join-Path $contradictoryState 'runs') $contradictoryRunId
    New-Item -ItemType Directory -Path $contradictoryRun -Force | Out-Null
    $contradictoryStoredConfiguration = New-FixtureRunConfiguration `
        -RunId $contradictoryRunId `
        -SteamVrRoot $fakeRuntime `
        -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $null = Write-FixtureRunConfiguration -RunDirectory $contradictoryRun -Configuration $contradictoryStoredConfiguration
    [pscustomobject]@{ runId=$contradictoryRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $contradictoryState 'active-run.json') -Encoding utf8NoBOM
    '{"phase":"stopped","updatedUtc":"2026-01-01T00:00:00Z"}' | Set-Content -LiteralPath (Join-Path $contradictoryRun 'status.json') -Encoding utf8NoBOM
    $contradictoryResult = Stop-SteamVrHeadlessRun -RunId $contradictoryRunId -StateRoot $contradictoryState
    Assert-True $contradictoryResult.ok 'Stop trusted or rejected a contradictory terminal status instead of verifying cleanup.'
    Assert-True (-not (Test-Path -LiteralPath $contradictoryState)) 'Verified cleanup retained contradictory active state.'
    Complete-Test 'active terminal status is revalidated'

    Remove-Item -LiteralPath $stateRoot -Recurse -Force
    $badStartupPath = Join-Path $fakeRuntime 'bin\win64\vrstartup.exe'
    [System.IO.File]::WriteAllText($badStartupPath, 'not an executable')
    $startResult = Start-SteamVrHeadlessRun `
        -SteamVrRoot $fakeRuntime `
        -StateRoot $stateRoot `
        -SupervisorScriptPath $supervisorScript
    Assert-True (-not $startResult.ok) 'The invalid startup executable did not fail the detached run.'
    Assert-Equal $startResult.run.phase 'failed' 'The detached supervisor did not report a controlled failure.'
    Assert-True ($null -eq $startResult.PSObject.Properties['prunedRuns']) 'Start returned internal pruning details.'
    Assert-True ($null -eq $startResult.run.PSObject.Properties['reason']) 'The run status retained a duplicate reason field.'
    Assert-True ($null -eq $startResult.run.PSObject.Properties['cleanupComplete']) 'The run status retained a duplicate cleanup-complete flag.'
    Assert-True $startResult.run.cleanup.lockRemoved 'The detached supervisor did not remove its active lock.'
    Assert-Equal $startResult.run.environment.VR_OVERRIDE ([IO.Path]::GetFullPath($fakeRuntime)) 'The run did not report its runtime override.'
    Assert-True ($startResult.run.environment.VR_CONFIG_PATH -match [regex]::Escape($startResult.runId)) 'The run did not report its private config environment.'
    $failedRunDirectory = Join-Path (Join-Path $stateRoot 'runs') $startResult.runId
    $storedFailedRun = Get-Content -Raw -LiteralPath (Join-Path $failedRunDirectory 'run.json') | ConvertFrom-Json
    Assert-True ($null -eq $storedFailedRun.PSObject.Properties['supervisor']) 'The supervisor rewrote the immutable run configuration.'
    Assert-True ($null -eq $storedFailedRun.PSObject.Properties['startupTimeoutSeconds']) 'The stored run configuration contains a fixed startup timeout.'
    Assert-True ($null -eq $storedFailedRun.PSObject.Properties['privateConfigRoot']) 'The stored run configuration contains a derived path.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $failedRunDirectory 'launch.json'))) 'The detached supervisor created a separate launch record.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $failedRunDirectory 'events.log'))) 'The detached supervisor created a duplicate event log.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'active-run.json'))) 'The detached failure left an active-run lock.'
    $failedStatus = Get-SteamVrHeadlessStatus -RunId $startResult.runId -StateRoot $stateRoot
    Assert-True $failedStatus.ok 'Status could not read a retained completed run.'
    Assert-True (-not $failedStatus.active) 'Status reported a retained run as active.'
    Assert-True (-not $failedStatus.supervisorAlive) 'Status reported a retained supervisor as active.'
    Assert-Equal $failedStatus.runtimeProcesses.Count 0 'Status attributed current runtime processes to a retained run.'
    $failedCheck = Invoke-SteamVrHeadlessCheck -SteamVrRoot $fakeRuntime -StateRoot $stateRoot
    Assert-Equal $failedCheck.inactiveRuns.Count 1 'The retained failed run was invisible to check.'
    Complete-Test 'detached supervisor failure cleanup'

    $pruneRunId = [Guid]::NewGuid().ToString('N')
    $pruneRun = Join-Path (Join-Path $stateRoot 'runs') $pruneRunId
    New-Item -ItemType Directory -Path $pruneRun -Force | Out-Null
    & $module { param($State, $Id) New-ActiveRunRecord -StateRoot $State -RunId $Id } $stateRoot $pruneRunId
    & $module {
        param($State, $Id, $Directory)
        Remove-InactiveRunDirectories -StateRoot $State -ActiveRunId $Id -ActiveRunDirectory $Directory
    } $stateRoot $pruneRunId $pruneRun
    Assert-True (-not (Test-Path -LiteralPath $failedRunDirectory)) 'A new lock owner did not remove the retained run state.'
    & $module { param($State, $Id) Remove-ActiveRunRecord -StateRoot $State -RunId $Id } $stateRoot $pruneRunId | Out-Null
    Remove-Item -LiteralPath $pruneRun -Recurse -Force
    Complete-Test 'new owner removes retained runs'

    $staleState = Join-Path $testRoot 'stale-state'
    $staleRunId = [Guid]::NewGuid().ToString('N')
    $staleRun = Join-Path (Join-Path $staleState 'runs') $staleRunId
    New-Item -ItemType Directory -Path $staleRun -Force | Out-Null
    $storedStaleConfiguration = New-FixtureRunConfiguration -RunId $staleRunId -SteamVrRoot $fakeRuntime -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $staleConfiguration = Write-FixtureRunConfiguration -RunDirectory $staleRun -Configuration $storedStaleConfiguration
    New-Item -ItemType Directory -Path $staleConfiguration.privateConfigRoot, $staleConfiguration.privateLogRoot -Force | Out-Null
    [pscustomobject]@{ runId=$staleRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staleState 'active-run.json') -Encoding utf8NoBOM

    $fakeVrServer = Join-Path $fakeRuntime 'bin\win64\vrserver.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\ping.exe') -Destination $fakeVrServer -Force
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $fakeVrServer
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    [void]$processInfo.ArgumentList.Add('127.0.0.1')
    [void]$processInfo.ArgumentList.Add('-n')
    [void]$processInfo.ArgumentList.Add('60')
    $fakeVrProcess = [System.Diagnostics.Process]::Start($processInfo)
    try {
        $discoveryDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $discovered = @(& $module { param($Root) Get-SteamVrRuntimeProcesses -SteamVrRoot $Root } $fakeRuntime)
            if ($discovered.Count -gt 0) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $discoveryDeadline)
        Assert-True ($discovered.Count -gt 0) 'The fake SteamVR process was not discoverable.'

        $staleResult = Stop-SteamVrHeadlessRun -RunId $staleRunId -StateRoot $staleState
        Assert-True $staleResult.ok ("Stop did not clean a run with a dead supervisor: " + ($staleResult | ConvertTo-Json -Depth 8 -Compress))
        $fakeVrProcess.Refresh()
        Assert-True $fakeVrProcess.HasExited 'Dead-run cleanup left a runtime-root process alive.'
        Assert-True (-not (Test-Path -LiteralPath $staleState)) 'Dead-run cleanup left state artifacts.'
    } finally {
        if (-not $fakeVrProcess.HasExited) { Stop-Process -Id $fakeVrProcess.Id -Force -ErrorAction SilentlyContinue }
        $fakeVrProcess.Dispose()
    }
    Complete-Test 'dead stop rescans runtime root'

    $orphanState = Join-Path $testRoot 'orphan-state'
    $orphanRunId = [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $orphanState -Force | Out-Null
    [pscustomobject]@{ runId=$orphanRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $orphanState 'active-run.json') -Encoding utf8NoBOM
    $orphanResult = Stop-SteamVrHeadlessRun -RunId $orphanRunId -StateRoot $orphanState
    Assert-True (-not $orphanResult.ok) 'An orphan active-run lock reported successful stop.'
    Assert-True (Test-Path -LiteralPath (Join-Path $orphanState 'active-run.json')) 'An orphan active-run lock was removed without its run state.'
    Complete-Test 'orphan active-run lock is refused'

    $unregisteredState = Join-Path $testRoot 'unregistered-supervisor-state'
    $unregisteredRunId = [Guid]::NewGuid().ToString('N')
    $unregisteredRun = Join-Path (Join-Path $unregisteredState 'runs') $unregisteredRunId
    New-Item -ItemType Directory -Path $unregisteredRun -Force | Out-Null
    $unregisteredConfiguration = New-FixtureRunConfiguration -RunId $unregisteredRunId -SteamVrRoot $fakeRuntime
    $null = Write-FixtureRunConfiguration -RunDirectory $unregisteredRun -Configuration $unregisteredConfiguration
    [pscustomobject]@{ runId=$unregisteredRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $unregisteredState 'active-run.json') -Encoding utf8NoBOM
    $unregisteredResult = Stop-SteamVrHeadlessRun -RunId $unregisteredRunId -StateRoot $unregisteredState
    Assert-True $unregisteredResult.ok 'Stop did not clean a run before supervisor registration.'
    Assert-True (-not (Test-Path -LiteralPath $unregisteredState)) 'Pre-registration stop left state artifacts.'
    Complete-Test 'stop cleans an unregistered supervisor immediately'

    $currentSupervisor = & $module { Get-CurrentProcessRecord }
    $reusedIdentity = [pscustomobject]@{
        pid = $currentSupervisor.pid
        name = $currentSupervisor.name
        path = $currentSupervisor.path
        creationUtc = ([DateTime]::Parse([string]$currentSupervisor.creationUtc)).ToUniversalTime().AddMinutes(-1).ToString('o')
    }
    $reusedAlive = & $module { param($Record) Get-SupervisorAlive -Supervisor $Record } $reusedIdentity
    Assert-True (-not $reusedAlive) 'A reused supervisor PID was accepted without matching creation time.'
    Complete-Test 'supervisor identity rejects PID reuse'

    $malformedState = Join-Path $testRoot 'malformed-state'
    $malformedRunId = [Guid]::NewGuid().ToString('N')
    $malformedRun = Join-Path (Join-Path $malformedState 'runs') $malformedRunId
    New-Item -ItemType Directory -Path $malformedRun -Force | Out-Null
    $malformedResult = Stop-SteamVrHeadlessRun -RunId $malformedRunId -StateRoot $malformedState
    Assert-True $malformedResult.ok 'Stop rejected malformed inactive private state.'
    Assert-True (-not (Test-Path -LiteralPath $malformedRun)) 'Stop retained malformed inactive private state.'
    Complete-Test 'stop removes malformed inactive private state'

    $malformedActiveState = Join-Path $testRoot 'malformed-active-state'
    $malformedActiveRunId = [Guid]::NewGuid().ToString('N')
    $malformedActiveRun = Join-Path (Join-Path $malformedActiveState 'runs') $malformedActiveRunId
    New-Item -ItemType Directory -Path $malformedActiveRun -Force | Out-Null
    [pscustomobject]@{ runId=$malformedActiveRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $malformedActiveState 'active-run.json') -Encoding utf8NoBOM
    $malformedActiveResult = Stop-SteamVrHeadlessRun -RunId $malformedActiveRunId -StateRoot $malformedActiveState
    Assert-True (-not $malformedActiveResult.ok) 'Malformed active state reported successful stop.'
    Assert-True (Test-Path -LiteralPath $malformedActiveRun) 'Stop deleted malformed active state.'
    Assert-True (Test-Path -LiteralPath (Join-Path $malformedActiveState 'active-run.json')) 'Stop removed the lock for malformed active state.'
    Complete-Test 'malformed active state is refused'

    $cancelState = Join-Path $testRoot 'cancel-state'
    $cancelRunId = [Guid]::NewGuid().ToString('N')
    $cancelRun = Join-Path (Join-Path $cancelState 'runs') $cancelRunId
    New-Item -ItemType Directory -Path $cancelRun -Force | Out-Null
    $cancelConfiguration = New-FixtureRunConfiguration -RunId $cancelRunId -SteamVrRoot $fakeRuntime -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $cancelRuntimeConfiguration = Write-FixtureRunConfiguration -RunDirectory $cancelRun -Configuration $cancelConfiguration
    [pscustomobject]@{ runId=$cancelRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cancelState 'active-run.json') -Encoding utf8NoBOM
    'requested' | Set-Content -LiteralPath (Join-Path $cancelRun 'stop.request') -Encoding utf8NoBOM
    Invoke-SteamVrHeadlessSupervisor -RunId $cancelRunId -StateRoot $cancelState
    $cancelStatus = Get-Content -Raw -LiteralPath (Join-Path $cancelRun 'status.json') | ConvertFrom-Json
    Assert-Equal $cancelStatus.phase 'starting' 'A pre-start stop request allowed the supervisor to enter runtime startup.'
    Assert-True ($null -ne $cancelStatus.supervisor.pid) 'The supervisor did not register itself in the initial status.'
    Assert-True (-not (Test-Path -LiteralPath $cancelRuntimeConfiguration.privateConfigRoot)) 'A pre-start stop request created private runtime configuration.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $cancelRun 'launch.json'))) 'Supervisor self-registration created a separate launch record.'
    $cancelCleanup = & $module {
        param($RunDirectory, $StateRoot, $Configuration)
        Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
    } $cancelRun $cancelState $cancelRuntimeConfiguration
    Assert-True $cancelCleanup.complete 'The stopped pre-start supervisor left state that could not be cleaned.'
    Remove-Item -LiteralPath $cancelState -Recurse -Force
    Complete-Test 'stop marker prevents supervisor startup'

    $leaseState = Join-Path $testRoot 'lease-state'
    $leaseRunId = [Guid]::NewGuid().ToString('N')
    $leaseRun = Join-Path (Join-Path $leaseState 'runs') $leaseRunId
    New-Item -ItemType Directory -Path $leaseRun -Force | Out-Null
    $leaseConfiguration = New-FixtureRunConfiguration -RunId $leaseRunId -SteamVrRoot $fakeRuntime -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-2)) -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $null = Write-FixtureRunConfiguration -RunDirectory $leaseRun -Configuration $leaseConfiguration
    [pscustomobject]@{ runId=$leaseRunId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $leaseState 'active-run.json') -Encoding utf8NoBOM
    Invoke-SteamVrHeadlessSupervisor -RunId $leaseRunId -StateRoot $leaseState
    $leaseStatus = Get-Content -Raw -LiteralPath (Join-Path $leaseRun 'status.json') | ConvertFrom-Json
    Assert-Equal $leaseStatus.phase 'expired' 'An expired lease entered normal startup.'
    Assert-True ($null -ne $leaseStatus.supervisor.pid) 'The expired supervisor did not self-register in status.'
    Assert-True ($null -eq $leaseStatus.PSObject.Properties['reason']) 'The expired status retained a duplicate reason field.'
    Assert-True ($null -eq $leaseStatus.PSObject.Properties['cleanupComplete']) 'An expired lease retained a duplicate cleanup-complete flag.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $leaseState 'active-run.json'))) 'An expired pre-start lease left its active lock.'
    Complete-Test 'lease is a hard startup deadline'

    [pscustomobject]@{
        ok = $true
        passed = $passed.Count
        tests = @($passed)
    } | ConvertTo-Json -Depth 5
    exit 0
} catch {
    [pscustomobject]@{
        ok = $false
        passed = $passed.Count
        tests = @($passed)
        error = $_.Exception.Message
        line = $_.InvocationInfo.ScriptLineNumber
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
}
