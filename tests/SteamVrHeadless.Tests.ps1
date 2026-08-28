[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\SteamVrHeadless.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru
$entryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\steamvr-headless.ps1'
$testRoot = Join-Path $env:TEMP ("steamvr-headless-tests-" + [Guid]::NewGuid().ToString('N'))
$passed = [System.Collections.Generic.List[string]]::new()

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
        [Parameter(Mandatory)][string]$SteamRoot,
        [Parameter(Mandatory)][string]$SteamVrRoot,
        [Parameter(Mandatory)][string]$SettingsPath,
        [DateTime]$CreatedUtc = [DateTime]::UtcNow,
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMinutes(10)
    )

    [pscustomobject][ordered]@{
        schemaVersion = 1
        runId = $RunId
        createdUtc = $CreatedUtc.ToString('o')
        deadlineUtc = $DeadlineUtc.ToString('o')
        startupTimeoutSeconds = 15
        steamRoot = $SteamRoot
        steamVrRoot = $SteamVrRoot
        configRoot = Join-Path $SteamRoot 'config'
        settingsPath = $SettingsPath
        vrStartupPath = Join-Path $SteamVrRoot 'bin\win64\vrstartup.exe'
        vrServerLog = Join-Path $SteamRoot 'logs\vrserver.txt'
        supervisor = $null
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $inputSettings = @'
{
  "steamvr": {
    "requireHmd": true,
    "forcedDriver": "future_hmd",
    "activateMultipleDrivers": true,
    "preserveMe": 42
  },
  "unrelated": {
    "value": "kept"
  }
}
'@
    $headlessText = & $module { param($Text) ConvertTo-HeadlessSettingsText -InputText $Text } $inputSettings
    $headless = $headlessText | ConvertFrom-Json
    Assert-Equal $headless.steamvr.requireHmd $false 'requireHmd was not disabled.'
    Assert-Equal $headless.steamvr.forcedDriver 'null' 'The null driver was not forced.'
    Assert-Equal $headless.steamvr.activateMultipleDrivers $false 'Multiple drivers were not disabled.'
    Assert-Equal $headless.driver_null.enable $true 'The null driver was not enabled.'
    Assert-Equal $headless.dashboard.enableDashboard $false 'The dashboard was not disabled.'
    Assert-Equal $headless.steamvr.preserveMe 42 'An unrelated SteamVR setting changed.'
    Assert-Equal $headless.unrelated.value 'kept' 'An unrelated section changed.'
    Complete-Test 'headless settings transformation'

    $futureUtc = [DateTime]::UtcNow.AddMinutes(10)
    $deserializedUtc = ([pscustomobject]@{ value=$futureUtc.ToString('o') } | ConvertTo-Json | ConvertFrom-Json).value
    $convertedUtc = & $module { param($Value) ConvertTo-UtcDateTime $Value } $deserializedUtc
    Assert-True ([Math]::Abs(($convertedUtc - $futureUtc).TotalMilliseconds) -lt 1) 'A deserialized UTC timestamp changed during conversion.'
    Assert-True ($convertedUtc -gt [DateTime]::UtcNow) 'A future UTC deadline became expired during conversion.'
    Complete-Test 'UTC timestamp conversion'

    $emptyStatus = & $module {
        $state = [ordered]@{supervisor=$null;ready=$false;restored=$true;reason=$null;error=$null;deadlineUtc=$null;evidence=$null;processes=$null;restoration=$null}
        New-RunStatus -RunId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -Phase 'stopped' -Message 'done' -State $state
    }
    Assert-Equal $emptyStatus.processes.Count 0 'An empty process set was serialized as a null process entry.'
    Complete-Test 'empty process status serialization'

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

    $cursorLogPath = Join-Path $testRoot 'cursor.log'
    [System.IO.File]::WriteAllText($cursorLogPath, ('x' * 100))
    $logCursor = & $module { param($Path) New-TextCursor -Path $Path } $cursorLogPath
    [System.IO.File]::WriteAllText($cursorLogPath, ('x' * 90))
    $null = & $module { param($Path, $Cursor) Read-TextFromCursor -Path $Path -Cursor $Cursor } $cursorLogPath $logCursor
    Assert-Equal $logCursor.offset 0 'The log cursor did not retain its reset after truncation.'
    [System.IO.File]::AppendAllText($cursorLogPath, "`nLoaded server driver tomorrow_headset (IServerTrackedDeviceProvider_004)")
    $rotatedText = & $module { param($Path, $Cursor) Read-TextFromCursor -Path $Path -Cursor $Cursor } $cursorLogPath $logCursor
    $rotatedAssessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $rotatedText
    Assert-True $rotatedAssessment.modeViolation 'The reset log cursor skipped a driver event across the old offset.'
    Complete-Test 'log cursor retains truncation reset'

    [System.IO.File]::WriteAllText($cursorLogPath, ('x' * 100))
    $replacementCursor = & $module { param($Path) New-TextCursor -Path $Path } $cursorLogPath
    $replacementText = ('y' * 90) + "`nLoaded server driver tomorrow_headset (IServerTrackedDeviceProvider_004)"
    [System.IO.File]::WriteAllText($cursorLogPath, $replacementText)
    Assert-True ((Get-Item -LiteralPath $cursorLogPath).Length -gt 100) 'The replacement log did not grow past the original offset.'
    $regrownText = & $module { param($Path, $Cursor) Read-TextFromCursor -Path $Path -Cursor $Cursor } $cursorLogPath $replacementCursor
    $regrownAssessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $regrownText
    Assert-True $replacementCursor.reset 'The log anchor did not identify replacement and regrowth between polls.'
    Assert-Equal $replacementCursor.offset 0 'The replaced log cursor did not reset to byte zero.'
    Assert-True $regrownAssessment.modeViolation 'Log replacement skipped a complete driver event before the old offset.'
    Complete-Test 'log cursor detects replacement and regrowth'

    $filesRoot = Join-Path $testRoot 'files'
    $backupRoot = Join-Path $testRoot 'backup'
    $manifestPath = Join-Path $testRoot 'manifest.json'
    New-Item -ItemType Directory -Path $filesRoot -Force | Out-Null
    $existingPath = Join-Path $filesRoot 'existing.bin'
    $absentPath = Join-Path $filesRoot 'absent.bin'
    $originalBytes = [byte[]](0, 1, 2, 13, 10, 255, 42)
    [System.IO.File]::WriteAllBytes($existingPath, $originalBytes)
    $originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $existingPath).Hash
    $protectedPaths = @($existingPath, $absentPath)

    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } $protectedPaths $backupRoot $manifestPath

    $manifest = @(Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json)
    Assert-True ($null -eq $manifest[0].PSObject.Properties['creationUtc']) 'The manifest still records creation time.'
    Assert-True ($null -eq $manifest[0].PSObject.Properties['lastWriteUtc']) 'The manifest still records write time.'
    Assert-True ($null -eq $manifest[0].PSObject.Properties['lastAccessUtc']) 'The manifest still records access time.'
    Assert-True ($null -eq $manifest[0].PSObject.Properties['attributes']) 'The manifest still records file attributes.'

    [System.IO.File]::WriteAllText($existingPath, 'changed')
    [System.IO.File]::WriteAllText($absentPath, 'created during run')
    $restoration = & $module { param($Manifest, $Expected) Restore-ProtectedFileManifest -ManifestPath $Manifest -ExpectedPaths $Expected } $manifestPath $protectedPaths
    Assert-True $restoration.restored 'The protected-file restoration reported failure.'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $existingPath).Hash $originalHash 'Existing bytes were not restored exactly.'
    Assert-True (-not (Test-Path -LiteralPath $absentPath)) 'A file absent before the run was not removed.'
    Complete-Test 'protected bytes and existence restoration'

    $corruptManifestPath = Join-Path $testRoot 'corrupt-manifest.json'
    $corruptBackupRoot = Join-Path $testRoot 'corrupt-backup'
    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } @($existingPath) $corruptBackupRoot $corruptManifestPath
    $corruptManifest = @(Get-Content -Raw -LiteralPath $corruptManifestPath | ConvertFrom-Json)
    [System.IO.File]::WriteAllText($existingPath, 'current bytes must survive')
    $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $existingPath).Hash
    [System.IO.File]::WriteAllText([string]$corruptManifest[0].backup, 'corrupt backup')
    $corruptResult = & $module { param($Manifest, $Expected) Restore-ProtectedFileManifest -ManifestPath $Manifest -ExpectedPaths $Expected } $corruptManifestPath @($existingPath)
    Assert-True (-not $corruptResult.restored) 'A corrupt backup was accepted.'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $existingPath).Hash $currentHash 'The destination was overwritten before backup validation.'
    Complete-Test 'backup validation before restoration'

    $fakeSteam = Join-Path $testRoot 'Steam'
    $fakeConfig = Join-Path $fakeSteam 'config'
    $fakeRuntime = Join-Path $fakeSteam 'steamapps\common\SteamVR'
    New-Item -ItemType Directory -Path (Join-Path $fakeRuntime 'bin\win64') -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeConfig -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fakeRuntime 'bin\win64\vrstartup.exe'), '')
    $settingsPath = Join-Path $fakeConfig 'steamvr.vrsettings'
    [System.IO.File]::WriteAllText($settingsPath, '{"steamvr":{}}')
    $stateRoot = Join-Path $testRoot 'state'
    $check = Invoke-SteamVrHeadlessCheck -SteamRoot $fakeSteam -StateRoot $stateRoot
    Assert-True $check.ok 'The read-only check failed for valid fixture paths.'
    Assert-True $check.canStart 'The read-only check rejected an idle valid fixture.'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $lockRunId = [Guid]::NewGuid().ToString('N')
    $lockRunDirectory = Join-Path (Join-Path $stateRoot 'runs') $lockRunId
    [pscustomobject]@{ schemaVersion=1;runId=$lockRunId;runDirectory=$lockRunDirectory;createdUtc=[DateTime]::UtcNow.ToString('o');supervisor=$null } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'active-run.json') -Encoding utf8NoBOM
    $check = Invoke-SteamVrHeadlessCheck -SteamRoot $fakeSteam -StateRoot $stateRoot
    Assert-True $check.ok 'The read-only check could not inspect a valid active-run lock.'
    Assert-True (-not $check.canStart) 'The read-only check ignored an active-run lock.'
    Remove-Item -LiteralPath (Join-Path $stateRoot 'active-run.json') -Force
    $pendingDirectory = Join-Path (Join-Path $stateRoot 'runs') 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    New-Item -ItemType Directory -Path $pendingDirectory -Force | Out-Null
    '{"phase":"recovery-required","restored":false}' | Set-Content -LiteralPath (Join-Path $pendingDirectory 'status.json') -Encoding utf8NoBOM
    $check = Invoke-SteamVrHeadlessCheck -SteamRoot $fakeSteam -StateRoot $stateRoot
    Assert-True (-not $check.canStart) 'The read-only check ignored an unfinished run journal.'
    Assert-Equal $check.pendingRuns.Count 1 'The unfinished run journal was not reported.'
    Complete-Test 'preflight and unfinished-run lock'

    $victimDirectory = Join-Path $stateRoot 'victim'
    New-Item -ItemType Directory -Path $victimDirectory -Force | Out-Null
    'keep' | Set-Content -LiteralPath (Join-Path $victimDirectory 'marker.txt') -Encoding utf8NoBOM
    $traversalOutput = & $entryScript stop -RunId '..\victim' -StateRoot $stateRoot 2>&1
    Assert-Equal $LASTEXITCODE 1 'A path-like run ID was accepted.'
    $null = ($traversalOutput -join "`n") | ConvertFrom-Json
    Assert-True (Test-Path -LiteralPath (Join-Path $victimDirectory 'marker.txt')) 'A path-like run ID escaped the runs directory.'
    Complete-Test 'run ID path boundary'

    $loserState = Join-Path $testRoot 'lock-loser-state'
    $loserResult = & $module {
        param($SteamRoot, $StateRoot, $EntryScript)
        $script:loserCleanupCalled = $false
        $originalNewActiveRunRecord = (Get-Command New-ActiveRunRecord -CommandType Function).ScriptBlock
        $originalInvokeRunCleanup = (Get-Command Invoke-RunCleanup -CommandType Function).ScriptBlock
        Set-Item -Path Function:New-ActiveRunRecord -Value { throw 'injected competing lock owner' }
        Set-Item -Path Function:Invoke-RunCleanup -Value {
            $script:loserCleanupCalled = $true
            throw 'destructive cleanup was called'
        }
        try {
            $startResult = Start-SteamVrHeadlessRun -SteamRoot $SteamRoot -StateRoot $StateRoot -EntryScriptPath $EntryScript -StartupTimeoutSeconds 15
            [pscustomobject]@{ start=$startResult;cleanupCalled=$script:loserCleanupCalled }
        } finally {
            Set-Item -Path Function:New-ActiveRunRecord -Value $originalNewActiveRunRecord
            Set-Item -Path Function:Invoke-RunCleanup -Value $originalInvokeRunCleanup
            Remove-Variable -Name loserCleanupCalled -Scope Script -ErrorAction SilentlyContinue
        }
    } $fakeSteam $loserState $entryScript
    Assert-True (-not $loserResult.start.ok) 'A start that lost the active lock reported success.'
    Assert-True (-not $loserResult.cleanupCalled) 'A start that lost the active lock invoked destructive cleanup.'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $loserState 'runs') -Directory -ErrorAction SilentlyContinue).Count) 0 'A start that lost the active lock retained its run directory.'
    Complete-Test 'competing start loser is non-destructive'

    $inspectionRecord = & $module { Get-CurrentProcessRecord }
    $inspectionResult = & $module {
        param($SteamRoot, $StateRoot, $Record)
        Set-Item -Path Function:Get-CimInstance -Value { throw 'injected process query failure' }
        try {
            $failedCheck = Invoke-SteamVrHeadlessCheck -SteamRoot $SteamRoot -StateRoot $StateRoot
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
    } $fakeSteam (Join-Path $testRoot 'query-failure-state') $inspectionRecord
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
    $ownershipConfiguration = New-FixtureRunConfiguration -RunId $ownershipRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $ownershipPaths = & $module { param($ConfigRoot) Get-ProtectedConfigPaths -ConfigRoot $ConfigRoot } $fakeConfig
    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } $ownershipPaths (Join-Path $ownershipRun 'backup') (Join-Path $ownershipRun 'protected-files.json')
    $ownershipOriginalBytes = [System.IO.File]::ReadAllBytes($settingsPath)
    [System.IO.File]::WriteAllText($settingsPath, 'temporary bytes owned by another run')
    $ownershipCurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    [pscustomobject]@{ schemaVersion=1;runId=$otherRunId;runDirectory=$otherRun;createdUtc=[DateTime]::UtcNow.ToString('o');supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ownershipState 'active-run.json') -Encoding utf8NoBOM
    try {
        $ownershipCleanup = & $module { param($RunDirectory, $StateRoot, $Configuration) Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration } $ownershipRun $ownershipState $ownershipConfiguration
        Assert-True (-not $ownershipCleanup.complete) 'Cleanup completed without owning the active lock.'
        Assert-True ($ownershipCleanup.error -match 'active lock') 'Cleanup did not report the ownership error.'
        Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $ownershipCurrentHash 'Cleanup restored files that belonged to another run.'
        $ownershipActive = Get-Content -Raw -LiteralPath (Join-Path $ownershipState 'active-run.json') | ConvertFrom-Json
        Assert-Equal $ownershipActive.runId $otherRunId 'Cleanup changed another run active lock.'
    } finally {
        [System.IO.File]::WriteAllBytes($settingsPath, $ownershipOriginalBytes)
    }
    Complete-Test 'cleanup requires exact active lock'

    $orderState = Join-Path $testRoot 'cleanup-order-state'
    $orderRunId = [Guid]::NewGuid().ToString('N')
    $orderRun = Join-Path (Join-Path $orderState 'runs') $orderRunId
    New-Item -ItemType Directory -Path $orderRun -Force | Out-Null
    $orderConfiguration = New-FixtureRunConfiguration -RunId $orderRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $orderConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $orderRun 'run.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$orderRunId;runDirectory=$orderRun;createdUtc=$orderConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $orderState 'active-run.json') -Encoding utf8NoBOM
    $orderPaths = & $module { param($ConfigRoot) Get-ProtectedConfigPaths -ConfigRoot $ConfigRoot } $fakeConfig
    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } $orderPaths (Join-Path $orderRun 'backup') (Join-Path $orderRun 'protected-files.json')
    $orderOriginalBytes = [System.IO.File]::ReadAllBytes($settingsPath)
    [System.IO.File]::WriteAllText($settingsPath, 'temporary bytes must remain while runtime remains')
    $orderCurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    & $module {
        Set-Item -Path Function:script:Stop-SteamVrRuntime -Value {
            param($SteamVrRoot, $SinceUtc)
            [pscustomobject]@{ graceful=@();forced=@();errors=@();remaining=@([pscustomobject]@{pid=1;name='vrserver'});verifiedStopped=$false }
        }
    }
    try {
        $orderCleanup = & $module { param($RunDirectory, $StateRoot, $Configuration) Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration } $orderRun $orderState $orderConfiguration
        Assert-True (-not $orderCleanup.complete) 'Cleanup completed while a runtime process remained.'
        Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $orderCurrentHash 'Cleanup restored files before runtime shutdown completed.'
        Assert-True (Test-Path -LiteralPath (Join-Path $orderState 'active-run.json')) 'Cleanup removed the lock while a runtime process remained.'
    } finally {
        & $module { Remove-Item -Path Function:script:Stop-SteamVrRuntime -Force }
        [System.IO.File]::WriteAllBytes($settingsPath, $orderOriginalBytes)
    }
    Complete-Test 'runtime stops before file restoration'

    Remove-Item -LiteralPath $stateRoot -Recurse -Force
    $badStartupPath = Join-Path $fakeRuntime 'bin\win64\vrstartup.exe'
    [System.IO.File]::WriteAllText($badStartupPath, 'not an executable')
    $settingsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    $startOutput = & $entryScript start -SteamRoot $fakeSteam -StateRoot $stateRoot -StartupTimeoutSeconds 15 2>&1
    Assert-Equal $LASTEXITCODE 1 'The invalid startup executable did not fail the detached run.'
    $startResult = ($startOutput -join "`n") | ConvertFrom-Json
    Assert-Equal $startResult.run.phase 'failed' 'The detached supervisor did not report a controlled failure.'
    Assert-True $startResult.run.restored 'The detached supervisor did not restore the protected files.'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $settingsHash 'The detached failure changed the fixture settings.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fakeConfig 'chaperone_info.vrchap'))) 'The detached failure left a chaperone file.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'active-run.json'))) 'The detached failure left an active-run lock.'
    $supervisorDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((Get-Process -Id ([int]$startResult.run.supervisorPid) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $supervisorDeadline) {
        Start-Sleep -Milliseconds 100
    }
    $recoverOutput = & $entryScript recover -StateRoot $stateRoot 2>&1
    Assert-Equal $LASTEXITCODE 0 'Recovery did not remove the restored failure journal.'
    $null = ($recoverOutput -join "`n") | ConvertFrom-Json
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'runs') -Directory -ErrorAction SilentlyContinue).Count) 0 'Recovery left a restored run journal.'
    Complete-Test 'detached supervisor failure restoration'

    $multipleState = Join-Path $testRoot 'multiple-journal-state'
    $staleOwnerRunId = [Guid]::NewGuid().ToString('N')
    $activeOwnerRunId = [Guid]::NewGuid().ToString('N')
    $staleOwnerRun = Join-Path (Join-Path $multipleState 'runs') $staleOwnerRunId
    $activeOwnerRun = Join-Path (Join-Path $multipleState 'runs') $activeOwnerRunId
    New-Item -ItemType Directory -Path $staleOwnerRun, $activeOwnerRun -Force | Out-Null
    $staleOwnerConfiguration = New-FixtureRunConfiguration -RunId $staleOwnerRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $activeOwnerConfiguration = New-FixtureRunConfiguration -RunId $activeOwnerRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath
    $staleOwnerConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $staleOwnerRun 'run.json') -Encoding utf8NoBOM
    $activeOwnerConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $activeOwnerRun 'run.json') -Encoding utf8NoBOM
    $multiplePaths = & $module { param($ConfigRoot) Get-ProtectedConfigPaths -ConfigRoot $ConfigRoot } $fakeConfig
    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } $multiplePaths (Join-Path $staleOwnerRun 'backup') (Join-Path $staleOwnerRun 'protected-files.json')
    [pscustomobject]@{ runId=$staleOwnerRunId;phase='configuring';restored=$false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staleOwnerRun 'status.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$activeOwnerRunId;runDirectory=$activeOwnerRun;createdUtc=$activeOwnerConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $multipleState 'active-run.json') -Encoding utf8NoBOM
    $multipleOriginalBytes = [System.IO.File]::ReadAllBytes($settingsPath)
    [System.IO.File]::WriteAllText($settingsPath, 'active owner temporary bytes')
    $multipleCurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    try {
        $multipleOutput = & $entryScript recover -StateRoot $multipleState 2>&1
        Assert-Equal $LASTEXITCODE 1 'Recovery reported success for an unfinished non-owner journal.'
        $multipleResult = ($multipleOutput -join "`n") | ConvertFrom-Json
        Assert-Equal $multipleResult.active.Count 1 'Recovery did not retain the active owner.'
        Assert-Equal $multipleResult.errors.Count 1 'Recovery did not report the unfinished non-owner journal.'
        Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $multipleCurrentHash 'Recovery restored an older run over the active owner.'
        $multipleActive = Get-Content -Raw -LiteralPath (Join-Path $multipleState 'active-run.json') | ConvertFrom-Json
        Assert-Equal $multipleActive.runId $activeOwnerRunId 'Recovery changed the active owner lock.'
    } finally {
        [System.IO.File]::WriteAllBytes($settingsPath, $multipleOriginalBytes)
    }
    Complete-Test 'recovery refuses unfinished non-owner journals'

    $staleState = Join-Path $testRoot 'stale-state'
    $staleRunId = [Guid]::NewGuid().ToString('N')
    $staleRun = Join-Path (Join-Path $staleState 'runs') $staleRunId
    New-Item -ItemType Directory -Path $staleRun -Force | Out-Null
    $staleManifest = Join-Path $staleRun 'protected-files.json'
    $staleChaperone = Join-Path $fakeConfig 'chaperone_info.vrchap'
    $staleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    $declaredPaths = & $module { param($ConfigRoot) Get-ProtectedConfigPaths -ConfigRoot $ConfigRoot } $fakeConfig
    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } $declaredPaths (Join-Path $staleRun 'backup') $staleManifest
    [System.IO.File]::WriteAllText($settingsPath, 'stale change')
    [System.IO.File]::WriteAllText($staleChaperone, 'stale file')
    $staleConfiguration = New-FixtureRunConfiguration -RunId $staleRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $staleConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $staleRun 'run.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$staleRunId;runDirectory=$staleRun;createdUtc=$staleConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $staleState 'active-run.json') -Encoding utf8NoBOM

    $fakeVrServer = Join-Path $fakeRuntime 'bin\win64\vrserver.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\ping.exe') -Destination $fakeVrServer
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

        $staleOutput = & $entryScript recover -StateRoot $staleState 2>&1
        Assert-Equal $LASTEXITCODE 0 ("Stale recovery returned an error: " + ($staleOutput -join "`n"))
        $staleResult = ($staleOutput -join "`n") | ConvertFrom-Json
        Assert-True $staleResult.ok 'Stale recovery did not report success.'
        $fakeVrProcess.Refresh()
        Assert-True $fakeVrProcess.HasExited 'Stale recovery left a runtime-root process alive.'
        Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $staleHash 'Stale recovery did not restore the settings.'
        Assert-True (-not (Test-Path -LiteralPath $staleChaperone)) 'Stale recovery did not remove the created file.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $staleState 'active-run.json'))) 'Stale recovery left the active-run lock.'
        Assert-True (-not (Test-Path -LiteralPath $staleRun)) 'Stale recovery left the recovered run journal.'
    } finally {
        if (-not $fakeVrProcess.HasExited) {
            Stop-Process -Id $fakeVrProcess.Id -Force -ErrorAction SilentlyContinue
        }
        $fakeVrProcess.Dispose()
    }
    Complete-Test 'stale recovery rescans runtime root'

    $orphanState = Join-Path $testRoot 'orphan-state'
    $orphanRunId = [Guid]::NewGuid().ToString('N')
    $orphanRun = Join-Path (Join-Path $orphanState 'runs') $orphanRunId
    New-Item -ItemType Directory -Path $orphanState -Force | Out-Null
    [pscustomobject]@{ schemaVersion=1;runId=$orphanRunId;runDirectory=$orphanRun;createdUtc=(Get-Date).ToUniversalTime().ToString('o');supervisor=$null } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $orphanState 'active-run.json') -Encoding utf8NoBOM
    $orphanOutput = & $entryScript recover -StateRoot $orphanState 2>&1
    Assert-Equal $LASTEXITCODE 1 'An orphan active-run lock was guessed away.'
    $orphanResult = ($orphanOutput -join "`n") | ConvertFrom-Json
    Assert-True (-not $orphanResult.ok) 'An orphan active-run lock reported success.'
    Assert-True (Test-Path -LiteralPath (Join-Path $orphanState 'active-run.json')) 'An orphan active-run lock was removed without its journal.'
    Complete-Test 'orphan active-run lock is refused'

    $handoffState = Join-Path $testRoot 'handoff-state'
    $handoffRunId = [Guid]::NewGuid().ToString('N')
    $handoffRun = Join-Path (Join-Path $handoffState 'runs') $handoffRunId
    New-Item -ItemType Directory -Path $handoffRun -Force | Out-Null
    $handoffConfiguration = New-FixtureRunConfiguration -RunId $handoffRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath
    $handoffConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $handoffRun 'run.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$handoffRunId;runDirectory=$handoffRun;createdUtc=$handoffConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $handoffState 'active-run.json') -Encoding utf8NoBOM
    $handoffOutput = & $entryScript recover -StateRoot $handoffState 2>&1
    Assert-Equal $LASTEXITCODE 0 'Recovery treated an in-progress handoff as stale.'
    $handoffResult = ($handoffOutput -join "`n") | ConvertFrom-Json
    Assert-Equal $handoffResult.active.Count 1 'Recovery did not report the pending handoff.'
    Assert-True (Test-Path -LiteralPath (Join-Path $handoffState 'active-run.json')) 'Recovery removed a pending handoff lock.'
    Complete-Test 'pending supervisor handoff is retained'

    $preflightState = Join-Path $testRoot 'preflight-state'
    $preflightRunId = [Guid]::NewGuid().ToString('N')
    $preflightRun = Join-Path (Join-Path $preflightState 'runs') $preflightRunId
    New-Item -ItemType Directory -Path $preflightRun -Force | Out-Null
    $preflightConfiguration = New-FixtureRunConfiguration -RunId $preflightRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $preflightConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $preflightRun 'run.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$preflightRunId;runDirectory=$preflightRun;createdUtc=$preflightConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $preflightState 'active-run.json') -Encoding utf8NoBOM
    $preflightOutput = & $entryScript recover -StateRoot $preflightState 2>&1
    Assert-Equal $LASTEXITCODE 0 'Pre-manifest recovery returned an error.'
    $preflightResult = ($preflightOutput -join "`n") | ConvertFrom-Json
    Assert-True $preflightResult.ok 'Pre-manifest recovery did not report success.'
    Assert-True (-not (Test-Path -LiteralPath $preflightState)) 'Pre-manifest recovery left state artifacts.'
    Complete-Test 'pre-manifest interruption recovery'

    $missingManifestState = Join-Path $testRoot 'missing-manifest-state'
    $missingManifestRunId = [Guid]::NewGuid().ToString('N')
    $missingManifestRun = Join-Path (Join-Path $missingManifestState 'runs') $missingManifestRunId
    New-Item -ItemType Directory -Path $missingManifestRun -Force | Out-Null
    $missingManifestConfiguration = New-FixtureRunConfiguration -RunId $missingManifestRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $missingManifestConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $missingManifestRun 'run.json') -Encoding utf8NoBOM
    [System.IO.File]::WriteAllText((Join-Path $missingManifestRun 'configuration-started'), [DateTime]::UtcNow.ToString('o'))
    [pscustomobject]@{ runId=$missingManifestRunId;phase='configuring';restored=$false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $missingManifestRun 'status.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$missingManifestRunId;runDirectory=$missingManifestRun;createdUtc=$missingManifestConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $missingManifestState 'active-run.json') -Encoding utf8NoBOM
    $missingManifestOriginalBytes = [System.IO.File]::ReadAllBytes($settingsPath)
    [System.IO.File]::WriteAllText($settingsPath, 'temporary settings with missing manifest')
    $missingManifestCurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    try {
        $missingManifestOutput = & $entryScript recover -StateRoot $missingManifestState 2>&1
        Assert-Equal $LASTEXITCODE 1 'Recovery reported success after a configured run lost its manifest.'
        $missingManifestResult = ($missingManifestOutput -join "`n") | ConvertFrom-Json
        Assert-True (-not $missingManifestResult.ok) 'A missing post-configuration manifest reported successful recovery.'
        Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $missingManifestCurrentHash 'Recovery changed settings without a manifest.'
        Assert-True (Test-Path -LiteralPath (Join-Path $missingManifestState 'active-run.json')) 'Recovery removed the lock for a missing manifest.'
        Assert-True (Test-Path -LiteralPath $missingManifestRun) 'Recovery removed evidence for a missing manifest.'
    } finally {
        [System.IO.File]::WriteAllBytes($settingsPath, $missingManifestOriginalBytes)
    }
    Complete-Test 'missing configured manifest is refused'

    $failedState = Join-Path $testRoot 'failed-state'
    $failedRunId = [Guid]::NewGuid().ToString('N')
    $failedRun = Join-Path (Join-Path $failedState 'runs') $failedRunId
    New-Item -ItemType Directory -Path $failedRun -Force | Out-Null
    $failedConfiguration = New-FixtureRunConfiguration -RunId $failedRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $failedConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $failedRun 'run.json') -Encoding utf8NoBOM
    $failedPaths = & $module { param($ConfigRoot) Get-ProtectedConfigPaths -ConfigRoot $ConfigRoot } $fakeConfig
    & $module {
        param($Paths, $Backup, $Manifest)
        New-ProtectedFileManifest -Paths $Paths -BackupDirectory $Backup -ManifestPath $Manifest | Out-Null
    } $failedPaths (Join-Path $failedRun 'backup') (Join-Path $failedRun 'protected-files.json')
    $failedManifest = @(Get-Content -Raw -LiteralPath (Join-Path $failedRun 'protected-files.json') | ConvertFrom-Json)
    $settingsEntry = @($failedManifest | Where-Object { $_.path -eq $settingsPath })[0]
    Remove-Item -LiteralPath ([string]$settingsEntry.backup) -Force
    [System.IO.File]::WriteAllText($settingsPath, 'leave current bytes on failed recovery')
    $failedCurrentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    [pscustomobject]@{ runId=$failedRunId;phase='configuring';restored=$false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $failedRun 'status.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$failedRunId;runDirectory=$failedRun;createdUtc=$failedConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $failedState 'active-run.json') -Encoding utf8NoBOM
    $failedOutput = & $entryScript recover -StateRoot $failedState 2>&1
    Assert-Equal $LASTEXITCODE 1 'Incomplete recovery returned success.'
    $failedResult = ($failedOutput -join "`n") | ConvertFrom-Json
    Assert-True (-not $failedResult.ok) 'Incomplete recovery reported success.'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $failedCurrentHash 'Failed backup validation overwrote current settings bytes.'
    Assert-True (Test-Path -LiteralPath (Join-Path $failedState 'active-run.json')) 'Incomplete recovery removed the safety lock.'
    Assert-True (Test-Path -LiteralPath $failedRun) 'Incomplete recovery removed its diagnostic journal.'
    Complete-Test 'incomplete recovery safety lock'

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
    $malformedOutput = & $entryScript recover -StateRoot $malformedState 2>&1
    Assert-Equal $LASTEXITCODE 1 'Recovery reported success for a run with no run.json.'
    $malformedResult = ($malformedOutput -join "`n") | ConvertFrom-Json
    Assert-True (-not $malformedResult.ok) 'Malformed recovery state was not reported as an error.'
    Assert-True (Test-Path -LiteralPath $malformedRun) 'Malformed recovery state was deleted automatically.'
    Complete-Test 'malformed journal is refused'

    [System.IO.File]::WriteAllText($settingsPath, '{"steamvr":{}}')
    $leaseState = Join-Path $testRoot 'lease-state'
    $leaseRunId = [Guid]::NewGuid().ToString('N')
    $leaseRun = Join-Path (Join-Path $leaseState 'runs') $leaseRunId
    New-Item -ItemType Directory -Path $leaseRun -Force | Out-Null
    $leaseConfiguration = New-FixtureRunConfiguration -RunId $leaseRunId -SteamRoot $fakeSteam -SteamVrRoot $fakeRuntime -SettingsPath $settingsPath -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-2)) -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $leaseConfiguration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $leaseRun 'run.json') -Encoding utf8NoBOM
    [pscustomobject]@{ schemaVersion=1;runId=$leaseRunId;runDirectory=$leaseRun;createdUtc=$leaseConfiguration.createdUtc;supervisor=$null } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $leaseState 'active-run.json') -Encoding utf8NoBOM
    $leaseSettingsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
    $leaseSupervisor = & $module { Get-CurrentProcessRecord }
    [pscustomobject]@{ schemaVersion=1;supervisor=$leaseSupervisor } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $leaseRun 'launch.json') -Encoding utf8NoBOM
    Invoke-SteamVrHeadlessSupervisor -RunId $leaseRunId -StateRoot $leaseState
    $leaseStatus = Get-Content -Raw -LiteralPath (Join-Path $leaseRun 'status.json') | ConvertFrom-Json
    Assert-Equal $leaseStatus.phase 'expired' 'An expired lease entered normal startup.'
    Assert-True $leaseStatus.restored 'An expired pre-start lease did not clean its journal state.'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash $leaseSettingsHash 'An expired pre-start lease changed settings bytes.'
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
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
