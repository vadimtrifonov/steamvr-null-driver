[CmdletBinding()]
param([Parameter(Mandatory)]$Context)

$module = $Context.Module

$tokens = $null
$parseErrors = $null
$entryAst = [Management.Automation.Language.Parser]::ParseFile(
    $Context.EntryScript,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-Equal $parseErrors.Count 0 'The public CLI script does not parse.'
$publicParameters = @(
    $entryAst.ParamBlock.Parameters |
        ForEach-Object { $_.Name.VariablePath.UserPath } |
        Sort-Object
)
Assert-Equal ($publicParameters -join ',') 'Action,MaxDurationMinutes,RunId,SteamVRRoot' 'The public CLI parameter set does not match the lifecycle contract.'
$entryCommand = Get-Command $Context.EntryScript
$actions = @(
    $entryCommand.Parameters['Action'].Attributes |
        Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } |
        Select-Object -ExpandProperty ValidValues |
        Sort-Object
)
Assert-Equal ($actions -join ',') 'check,start,status,stop' 'The public CLI action set does not match the lifecycle contract.'
foreach ($commandName in @('Get-SteamVRNullDriverStatus', 'Stop-SteamVRNullDriverRun')) {
    $runIdParameter = (Get-Command -Module $module.Name $commandName).Parameters['RunId']
    $parameterAttribute = @(
        $runIdParameter.Attributes |
            Where-Object { $_ -is [Management.Automation.ParameterAttribute] }
    )[0]
    Assert-True $parameterAttribute.Mandatory "$commandName does not require a run ID."
}
Complete-Test 'public CLI exposes check, start, status, and stop'

$checkStateRoot = Join-Path $Context.Root 'check-state'
$check = Invoke-SteamVRNullDriverCheck -SteamVRRoot $Context.SteamVRRoot -StateRoot $checkStateRoot
Assert-True $check.ok 'Check failed for an idle fixture runtime.'
Assert-True $check.canStart 'Check rejected an idle fixture runtime.'
Assert-PropertySet `
    -Value $check `
    -Names @(
        'ok',
        'action',
        'canStart',
        'steamVRRoot',
        'steamProcesses',
        'activeRun',
        'inactiveRuns',
        'runtimeProcesses'
    ) `
    -Message 'The check result has an unexpected shape.'
Assert-Equal $check.steamVRRoot ([IO.Path]::GetFullPath($Context.SteamVRRoot)) 'Check reported the wrong SteamVR root.'
Assert-Equal $check.steamProcesses.Count 1 'Check did not report the fixture Steam client.'
Assert-Equal $check.runtimeProcesses.Count 0 'Check reported processes under the idle fixture runtime.'
Complete-Test 'check reports the selected idle runtime'

& $module { $script:fixtureSteamClientProcesses = @() }
$withoutSteam = Invoke-SteamVRNullDriverCheck -SteamVRRoot $Context.SteamVRRoot -StateRoot $checkStateRoot
Assert-True $withoutSteam.ok 'A missing Steam client made check itself fail.'
Assert-True (-not $withoutSteam.canStart) 'Check allowed startup without Steam in the current session.'
& $module {
    $script:fixtureSteamClientProcesses = @([pscustomobject]@{
        pid = 1
        name = 'steam'
        path = 'C:\FixtureSteam\steam.exe'
        creationUtc = '2026-01-01T00:00:00Z'
    })
}
Complete-Test 'check requires Steam in the current interactive session'

New-Item -ItemType Directory -Path $checkStateRoot -Force | Out-Null
$activeCheckRunId = [Guid]::NewGuid().ToString('N')
[pscustomobject]@{ runId = $activeCheckRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $checkStateRoot 'active-run.json') -Encoding utf8NoBOM
$withActiveOwner = Invoke-SteamVRNullDriverCheck -SteamVRRoot $Context.SteamVRRoot -StateRoot $checkStateRoot
Assert-True $withActiveOwner.ok 'Check could not inspect active ownership.'
Assert-True (-not $withActiveOwner.canStart) 'Check allowed startup while another run owned the runtime.'
Assert-Equal $withActiveOwner.activeRun.runId $activeCheckRunId 'Check reported the wrong active owner.'
Remove-Item -LiteralPath $checkStateRoot -Recurse -Force
Complete-Test 'check reports active ownership as a start blocker'

$competingStateRoot = Join-Path $Context.Root 'competing-start-state'
$competingResult = & $module {
    param($RuntimeRoot, $StateRoot, $SupervisorScript)

    $script:cleanupCalled = $false
    $originalNewActiveRunRecord = (Get-Command New-ActiveRunRecord -CommandType Function).ScriptBlock
    $originalInvokeRunCleanup = (Get-Command Invoke-RunCleanup -CommandType Function).ScriptBlock
    Set-Item -Path Function:New-ActiveRunRecord -Value {
        throw 'injected active owner'
    }
    Set-Item -Path Function:Invoke-RunCleanup -Value {
        $script:cleanupCalled = $true
        throw 'cleanup must not run'
    }
    try {
        $start = Start-SteamVRNullDriverRun `
            -SteamVRRoot $RuntimeRoot `
            -StateRoot $StateRoot `
            -SupervisorScriptPath $SupervisorScript
        [pscustomobject]@{
            start = $start
            cleanupCalled = $script:cleanupCalled
        }
    } finally {
        Set-Item -Path Function:New-ActiveRunRecord -Value $originalNewActiveRunRecord
        Set-Item -Path Function:Invoke-RunCleanup -Value $originalInvokeRunCleanup
        Remove-Variable -Name cleanupCalled -Scope Script -ErrorAction SilentlyContinue
    }
} $Context.SteamVRRoot $competingStateRoot $Context.SupervisorScript
Assert-True (-not $competingResult.start.ok) 'A start that did not acquire ownership reported success.'
Assert-True (-not $competingResult.cleanupCalled) 'A start without ownership invoked runtime cleanup.'
Assert-PropertySet `
    -Value $competingResult.start `
    -Names @('ok', 'action', 'error') `
    -Message 'A start without retained state returned an unexpected result shape.'
Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $competingStateRoot 'runs') -Directory -ErrorAction SilentlyContinue).Count) 0 'A start without ownership retained private run state.'
Complete-Test 'start without ownership is non-destructive'

$pollingStateRoot = Join-Path $Context.Root 'start-polling-state'
$pollingResult = & $module {
    param($RuntimeRoot, $StateRoot, $SupervisorScript)

    $originalStartDetachedSupervisor = (Get-Command Start-DetachedSupervisor -CommandType Function).ScriptBlock
    Set-Item -Path Function:Start-DetachedSupervisor -Value {
        param($SupervisorScriptPath, $RunId, $StateRoot)
        [System.IO.File]::WriteAllText((Join-Path $StateRoot 'active-run.json'), '{')
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $start = Start-SteamVRNullDriverRun `
            -SteamVRRoot $RuntimeRoot `
            -StateRoot $StateRoot `
            -SupervisorScriptPath $SupervisorScript
        [pscustomobject]@{
            start = $start
            elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
        }
    } finally {
        Set-Item -Path Function:Start-DetachedSupervisor -Value $originalStartDetachedSupervisor
    }
} $Context.SteamVRRoot $pollingStateRoot $Context.SupervisorScript
Assert-True (-not $pollingResult.start.ok) 'Start polling accepted unreadable active state.'
Assert-True ([bool][string]$pollingResult.start.runId) 'Start polling did not preserve the run ID for retained state.'
Assert-True ($pollingResult.elapsedSeconds -lt 5) 'Unreadable active state became a startup timeout.'
Remove-Item -LiteralPath $pollingStateRoot -Recurse -Force
Complete-Test 'start reports unreadable active state immediately'

$deadReadyStateRoot = Join-Path $Context.Root 'dead-ready-state'
$deadReadyStart = & $module {
    param($RuntimeRoot, $StateRoot, $SupervisorScript)

    $originalStartDetachedSupervisor = (Get-Command Start-DetachedSupervisor -CommandType Function).ScriptBlock
    Set-Item -Path Function:Start-DetachedSupervisor -Value {
        param($SupervisorScriptPath, $RunId, $StateRoot)

        $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        [pscustomobject]@{
            runId = $RunId
            phase = 'ready'
            supervisor = [pscustomobject]@{
                pid = [int]::MaxValue
                path = 'C:\DeadFixture\pwsh.exe'
                creationUtc = '2026-01-01T00:00:00Z'
            }
        } |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $runDirectory 'status.json') -Encoding utf8NoBOM
    }
    try {
        Start-SteamVRNullDriverRun `
            -SteamVRRoot $RuntimeRoot `
            -StateRoot $StateRoot `
            -SupervisorScriptPath $SupervisorScript
    } finally {
        Set-Item -Path Function:Start-DetachedSupervisor -Value $originalStartDetachedSupervisor
    }
} $Context.SteamVRRoot $deadReadyStateRoot $Context.SupervisorScript
Assert-True (-not $deadReadyStart.ok) 'Start accepted ready state from a dead supervisor.'
Assert-True ([bool][string]$deadReadyStart.runId) 'Start did not retain the run ID after detecting a dead supervisor.'
Assert-Equal $deadReadyStart.run.phase 'ready' 'Start did not return the observed ready state for diagnosis.'
$deadReadyStop = Stop-SteamVRNullDriverRun -RunId $deadReadyStart.runId -StateRoot $deadReadyStateRoot
Assert-True $deadReadyStop.ok 'Stop did not clean the dead ready-supervisor fixture.'
Complete-Test 'start requires a live supervisor at readiness'

$terminalStateRoot = Join-Path $Context.Root 'active-terminal-state'
$terminalRunId = [Guid]::NewGuid().ToString('N')
$terminalRunDirectory = Join-Path (Join-Path $terminalStateRoot 'runs') $terminalRunId
New-Item -ItemType Directory -Path $terminalRunDirectory -Force | Out-Null
$null = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $terminalRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $terminalRunId -SteamVRRoot $Context.SteamVRRoot)
[pscustomobject]@{ runId = $terminalRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $terminalStateRoot 'active-run.json') -Encoding utf8NoBOM
'{"phase":"stopped","updatedUtc":"2026-01-01T00:00:00Z"}' |
    Set-Content -LiteralPath (Join-Path $terminalRunDirectory 'status.json') -Encoding utf8NoBOM
$terminalStop = Stop-SteamVRNullDriverRun -RunId $terminalRunId -StateRoot $terminalStateRoot
Assert-True $terminalStop.ok 'Stop trusted terminal status instead of verifying active cleanup.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $terminalStateRoot 'active-run.json'))) 'Verified terminal cleanup retained active ownership.'
Assert-True (-not (Test-Path -LiteralPath $terminalRunDirectory)) 'Verified terminal cleanup retained private run state.'
Assert-True (Test-Path -LiteralPath $terminalStateRoot -PathType Container) 'Verified terminal cleanup removed the empty state namespace.'
Complete-Test 'active ownership is verified independently of terminal status'

$failedStartStateRoot = Join-Path $Context.Root 'failed-start-state'
$startupPath = Join-Path $Context.SteamVRRoot 'bin\win64\vrstartup.exe'
[System.IO.File]::WriteAllText($startupPath, 'not an executable')
$failedStart = Start-SteamVRNullDriverRun `
    -SteamVRRoot $Context.SteamVRRoot `
    -StateRoot $failedStartStateRoot `
    -SupervisorScriptPath $Context.SupervisorScript
Assert-True (-not $failedStart.ok) 'A runtime launch failure reported successful startup.'
Assert-PropertySet `
    -Value $failedStart `
    -Names @('ok', 'action', 'runId', 'error', 'run') `
    -Message 'The failed start result has an unexpected shape.'
Assert-Equal $failedStart.run.phase 'failed' 'A runtime launch failure did not reach failed state.'
Assert-PropertySet `
    -Value $failedStart.run `
    -Names @(
        'runId',
        'phase',
        'message',
        'updatedUtc',
        'supervisor',
        'error',
        'deadlineUtc',
        'environment',
        'evidence',
        'cleanup'
    ) `
    -Message 'The terminal run status has an unexpected shape.'
Assert-True $failedStart.run.cleanup.lockRemoved 'A runtime launch failure retained active ownership.'
Assert-Equal $failedStart.run.environment.VR_OVERRIDE ([IO.Path]::GetFullPath($Context.SteamVRRoot)) 'The failed run reported the wrong runtime environment.'
$failedRunDirectory = Join-Path (Join-Path $failedStartStateRoot 'runs') $failedStart.runId
$storedFailedRun = Get-Content -Raw -LiteralPath (Join-Path $failedRunDirectory 'run.json') | ConvertFrom-Json
Assert-PropertySet `
    -Value $storedFailedRun `
    -Names @('schemaVersion', 'runId', 'createdUtc', 'deadlineUtc', 'steamVRRoot') `
    -Message 'The stored failed run has an unexpected durable shape.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $failedStartStateRoot 'active-run.json'))) 'A failed run retained active ownership after cleanup.'
$failedStatus = Get-SteamVRNullDriverStatus -RunId $failedStart.runId -StateRoot $failedStartStateRoot
Assert-True $failedStatus.ok 'Status could not read the retained failed run.'
Assert-True (-not $failedStatus.active) 'Status reported a cleaned failed run as active.'
Assert-True (-not $failedStatus.supervisorAlive) 'Status reported the completed supervisor as alive.'
Complete-Test 'runtime launch failure records terminal state and releases ownership'

$deadSupervisorStateRoot = Join-Path $Context.Root 'dead-supervisor-state'
$deadSupervisorRunId = [Guid]::NewGuid().ToString('N')
$deadSupervisorRunDirectory = Join-Path (Join-Path $deadSupervisorStateRoot 'runs') $deadSupervisorRunId
New-Item -ItemType Directory -Path $deadSupervisorRunDirectory -Force | Out-Null
$deadSupervisorConfiguration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $deadSupervisorRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $deadSupervisorRunId -SteamVRRoot $Context.SteamVRRoot)
New-Item -ItemType Directory -Path $deadSupervisorConfiguration.privateConfigRoot, $deadSupervisorConfiguration.privateLogRoot -Force | Out-Null
[pscustomobject]@{ runId = $deadSupervisorRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $deadSupervisorStateRoot 'active-run.json') -Encoding utf8NoBOM
$fakeServerPath = Join-Path $Context.SteamVRRoot 'bin\win64\vrserver.exe'
Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\ping.exe') -Destination $fakeServerPath -Force
$processInfo = [System.Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = $fakeServerPath
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true
[void]$processInfo.ArgumentList.Add('127.0.0.1')
[void]$processInfo.ArgumentList.Add('-n')
[void]$processInfo.ArgumentList.Add('60')
$fakeServer = [System.Diagnostics.Process]::Start($processInfo)
try {
    $discoveryDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $runtimeProcesses = @(& $module {
            param($Root)
            Get-SteamVRRuntimeProcesses -SteamVRRoot $Root
        } $Context.SteamVRRoot)
        if ($runtimeProcesses.Count -gt 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $discoveryDeadline)
    Assert-True ($runtimeProcesses.Count -gt 0) 'The runtime-root fixture process was not discoverable.'

    $deadSupervisorStop = Stop-SteamVRNullDriverRun -RunId $deadSupervisorRunId -StateRoot $deadSupervisorStateRoot
    Assert-True $deadSupervisorStop.ok ("Stop did not clean a run without a live supervisor: " + ($deadSupervisorStop | ConvertTo-Json -Depth 8 -Compress))
    $fakeServer.Refresh()
    Assert-True $fakeServer.HasExited 'Stop left a runtime-root process alive.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $deadSupervisorStateRoot 'active-run.json'))) 'Dead-supervisor cleanup retained active ownership.'
    Assert-True (-not (Test-Path -LiteralPath $deadSupervisorRunDirectory)) 'Dead-supervisor cleanup retained private run state.'
} finally {
    if (-not $fakeServer.HasExited) {
        Stop-Process -Id $fakeServer.Id -Force -ErrorAction SilentlyContinue
    }
    $fakeServer.Dispose()
}
Complete-Test 'stop rescans the runtime when the supervisor is absent'

$orphanStateRoot = Join-Path $Context.Root 'orphan-state'
$orphanRunId = [Guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Path $orphanStateRoot -Force | Out-Null
[pscustomobject]@{ runId = $orphanRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $orphanStateRoot 'active-run.json') -Encoding utf8NoBOM
$orphanStop = Stop-SteamVRNullDriverRun -RunId $orphanRunId -StateRoot $orphanStateRoot
Assert-True (-not $orphanStop.ok) 'Stop accepted active ownership without run state.'
Assert-True (Test-Path -LiteralPath (Join-Path $orphanStateRoot 'active-run.json')) 'Stop removed active ownership without run state.'
Complete-Test 'stop preserves an orphan active lock'

$unregisteredStateRoot = Join-Path $Context.Root 'unregistered-supervisor-state'
$unregisteredRunId = [Guid]::NewGuid().ToString('N')
$unregisteredRunDirectory = Join-Path (Join-Path $unregisteredStateRoot 'runs') $unregisteredRunId
New-Item -ItemType Directory -Path $unregisteredRunDirectory -Force | Out-Null
$null = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $unregisteredRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $unregisteredRunId -SteamVRRoot $Context.SteamVRRoot)
[pscustomobject]@{ runId = $unregisteredRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $unregisteredStateRoot 'active-run.json') -Encoding utf8NoBOM
$unregisteredStop = Stop-SteamVRNullDriverRun -RunId $unregisteredRunId -StateRoot $unregisteredStateRoot
Assert-True $unregisteredStop.ok 'Stop did not clean a run before supervisor registration.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $unregisteredStateRoot 'active-run.json'))) 'Pre-registration cleanup retained active ownership.'
Assert-True (-not (Test-Path -LiteralPath $unregisteredRunDirectory)) 'Pre-registration cleanup retained private run state.'
Complete-Test 'stop cleans a run before supervisor registration'

$delayedSupervisorFailed = $false
try {
    Invoke-SteamVRNullDriverSupervisor -RunId $unregisteredRunId -StateRoot $unregisteredStateRoot
} catch {
    $delayedSupervisorFailed = $true
}
$delayedRuntimeProcesses = @(& $module {
    param($RuntimeRoot)
    Get-SteamVRRuntimeProcesses -SteamVRRoot $RuntimeRoot
} $Context.SteamVRRoot)
Assert-True $delayedSupervisorFailed 'A delayed supervisor continued without run state.'
Assert-True (-not (Test-Path -LiteralPath $unregisteredRunDirectory)) 'A delayed supervisor recreated stopped run state.'
Assert-Equal $delayedRuntimeProcesses.Count 0 'A delayed supervisor restarted the runtime.'
Complete-Test 'delayed supervisor cannot recreate a stopped run'

$malformedRetainedStateRoot = Join-Path $Context.Root 'malformed-retained-state'
$malformedRetainedRunId = [Guid]::NewGuid().ToString('N')
$malformedRetainedRunDirectory = Join-Path (Join-Path $malformedRetainedStateRoot 'runs') $malformedRetainedRunId
New-Item -ItemType Directory -Path $malformedRetainedRunDirectory -Force | Out-Null
$malformedRetainedStop = Stop-SteamVRNullDriverRun -RunId $malformedRetainedRunId -StateRoot $malformedRetainedStateRoot
Assert-True $malformedRetainedStop.ok 'Stop rejected retained state without a run configuration.'
Assert-True (-not (Test-Path -LiteralPath $malformedRetainedRunDirectory)) 'Stop retained inactive state without a run configuration.'
Complete-Test 'stop removes retained state without active ownership'

$malformedActiveStateRoot = Join-Path $Context.Root 'malformed-active-state'
$malformedActiveRunId = [Guid]::NewGuid().ToString('N')
$malformedActiveRunDirectory = Join-Path (Join-Path $malformedActiveStateRoot 'runs') $malformedActiveRunId
New-Item -ItemType Directory -Path $malformedActiveRunDirectory -Force | Out-Null
[pscustomobject]@{ runId = $malformedActiveRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $malformedActiveStateRoot 'active-run.json') -Encoding utf8NoBOM
$malformedActiveStop = Stop-SteamVRNullDriverRun -RunId $malformedActiveRunId -StateRoot $malformedActiveStateRoot
Assert-True (-not $malformedActiveStop.ok) 'Stop accepted active ownership without a run configuration.'
Assert-True (Test-Path -LiteralPath $malformedActiveRunDirectory) 'Stop deleted active state without a run configuration.'
Assert-True (Test-Path -LiteralPath (Join-Path $malformedActiveStateRoot 'active-run.json')) 'Stop removed ownership without a run configuration.'
Complete-Test 'stop preserves active state without a valid configuration'

$stopMarkerStateRoot = Join-Path $Context.Root 'stop-marker-state'
$stopMarkerRunId = [Guid]::NewGuid().ToString('N')
$stopMarkerRunDirectory = Join-Path (Join-Path $stopMarkerStateRoot 'runs') $stopMarkerRunId
New-Item -ItemType Directory -Path $stopMarkerRunDirectory -Force | Out-Null
$stopMarkerConfiguration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $stopMarkerRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $stopMarkerRunId -SteamVRRoot $Context.SteamVRRoot)
[pscustomobject]@{ runId = $stopMarkerRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $stopMarkerStateRoot 'active-run.json') -Encoding utf8NoBOM
'requested' | Set-Content -LiteralPath (Join-Path $stopMarkerRunDirectory 'stop.request') -Encoding utf8NoBOM
Invoke-SteamVRNullDriverSupervisor -RunId $stopMarkerRunId -StateRoot $stopMarkerStateRoot
$stopMarkerStatus = Get-Content -Raw -LiteralPath (Join-Path $stopMarkerRunDirectory 'status.json') | ConvertFrom-Json
Assert-Equal $stopMarkerStatus.phase 'starting' 'A stop marker allowed the supervisor to enter runtime startup.'
Assert-True ($null -ne $stopMarkerStatus.supervisor.pid) 'The supervisor did not register before observing the stop marker.'
Assert-True (-not (Test-Path -LiteralPath $stopMarkerConfiguration.privateConfigRoot)) 'A stopped supervisor created private runtime configuration.'
$stopMarkerCleanup = & $module {
    param($RunDirectory, $StateRoot, $Configuration)
    Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
} $stopMarkerRunDirectory $stopMarkerStateRoot $stopMarkerConfiguration
Assert-True $stopMarkerCleanup.complete 'The stopped supervisor left ownership that could not be cleaned.'
Remove-Item -LiteralPath $stopMarkerStateRoot -Recurse -Force
Complete-Test 'stop marker prevents supervisor startup'

$expiredLeaseStateRoot = Join-Path $Context.Root 'expired-lease-state'
$expiredLeaseRunId = [Guid]::NewGuid().ToString('N')
$expiredLeaseRunDirectory = Join-Path (Join-Path $expiredLeaseStateRoot 'runs') $expiredLeaseRunId
New-Item -ItemType Directory -Path $expiredLeaseRunDirectory -Force | Out-Null
$null = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $expiredLeaseRunDirectory `
    -Configuration (New-FixtureRunConfiguration `
        -RunId $expiredLeaseRunId `
        -SteamVRRoot $Context.SteamVRRoot `
        -CreatedUtc ([DateTime]::UtcNow.AddMinutes(-2)) `
        -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(-1)))
[pscustomobject]@{ runId = $expiredLeaseRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $expiredLeaseStateRoot 'active-run.json') -Encoding utf8NoBOM
Invoke-SteamVRNullDriverSupervisor -RunId $expiredLeaseRunId -StateRoot $expiredLeaseStateRoot
$expiredLeaseStatus = Get-Content -Raw -LiteralPath (Join-Path $expiredLeaseRunDirectory 'status.json') | ConvertFrom-Json
Assert-Equal $expiredLeaseStatus.phase 'expired' 'An expired lease entered runtime startup.'
Assert-True ($null -ne $expiredLeaseStatus.supervisor.pid) 'The expired lease has no supervisor identity.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $expiredLeaseStateRoot 'active-run.json'))) 'An expired lease retained active ownership.'
Assert-True $expiredLeaseStatus.cleanup.lockRemoved 'An expired lease did not report ownership removal.'
Complete-Test 'expired lease releases active ownership'
