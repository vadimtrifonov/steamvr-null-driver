[CmdletBinding()]
param([Parameter(Mandatory)]$Context)

$module = $Context.Module

$futureUtc = [DateTime]::UtcNow.AddMinutes(10)
$deserializedUtc = ([pscustomobject]@{ value = $futureUtc.ToString('o') } | ConvertTo-Json | ConvertFrom-Json).value
$convertedUtc = & $module { param($Value) ConvertTo-UtcDateTime $Value } $deserializedUtc
Assert-True ([Math]::Abs(($convertedUtc - $futureUtc).TotalMilliseconds) -lt 1) 'UTC conversion changed the stored instant.'
Assert-True ($convertedUtc -gt [DateTime]::UtcNow) 'UTC conversion changed a future deadline into an expired deadline.'
Complete-Test 'run timestamps preserve UTC'

$deletedRunDirectory = Join-Path $Context.Root 'deleted-run-directory'
$stateWriteFailed = $false
try {
    & $module {
        param($Path)
        Write-JsonAtomic -Path $Path -Value ([pscustomobject]@{ value = 'test' })
    } (Join-Path $deletedRunDirectory 'status.json')
} catch {
    $stateWriteFailed = $true
}
Assert-True $stateWriteFailed 'A state write succeeded without its run directory.'
Assert-True (-not (Test-Path -LiteralPath $deletedRunDirectory)) 'A state write recreated a deleted run directory.'
Complete-Test 'state writes require an existing run directory'

$lockStateRoot = Join-Path $Context.Root 'atomic-lock-state'
$ownerRunId = [Guid]::NewGuid().ToString('N')
$contenderRunId = [Guid]::NewGuid().ToString('N')
$ownerRunDirectory = Join-Path (Join-Path $lockStateRoot 'runs') $ownerRunId
$contenderRunDirectory = Join-Path (Join-Path $lockStateRoot 'runs') $contenderRunId
New-Item -ItemType Directory -Path $ownerRunDirectory, $contenderRunDirectory -Force | Out-Null
& $module {
    param($StateRoot, $RunId)
    New-ActiveRunRecord -StateRoot $StateRoot -RunId $RunId
} $lockStateRoot $ownerRunId
$contenderRejected = $false
try {
    & $module {
        param($StateRoot, $RunId)
        New-ActiveRunRecord -StateRoot $StateRoot -RunId $RunId
    } $lockStateRoot $contenderRunId
} catch {
    $contenderRejected = $true
}
$publishedOwner = & $module {
    param($StateRoot)
    Get-ActiveRunRecord -StateRoot $StateRoot
} $lockStateRoot
Assert-True $contenderRejected 'A competing run replaced active ownership.'
Assert-Equal $publishedOwner.runId $ownerRunId 'Failed lock publication changed the active owner.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $contenderRunDirectory 'active-run.tmp'))) 'Failed lock publication retained its temporary file.'
& $module {
    param($StateRoot, $RunId)
    Remove-ActiveRunRecord -StateRoot $StateRoot -RunId $RunId
} $lockStateRoot $ownerRunId | Out-Null
Remove-Item -LiteralPath $lockStateRoot -Recurse -Force
Complete-Test 'active ownership is published atomically'

$configurationRunId = [Guid]::NewGuid().ToString('N')
$configurationRunDirectory = Join-Path (Join-Path $Context.Root 'configuration-runs') $configurationRunId
New-Item -ItemType Directory -Path $configurationRunDirectory -Force | Out-Null
$storedConfiguration = New-FixtureRunConfiguration `
    -RunId $configurationRunId `
    -SteamVRRoot $Context.SteamVRRoot
$configuration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $configurationRunDirectory `
    -Configuration $storedConfiguration
Assert-PropertySet `
    -Value $storedConfiguration `
    -Names @('schemaVersion', 'runId', 'createdUtc', 'deadlineUtc', 'steamVRRoot') `
    -Message 'The durable run configuration has an unexpected shape.'
Assert-PropertySet `
    -Value $configuration `
    -Names @(
        'schemaVersion',
        'runId',
        'createdUtc',
        'deadlineUtc',
        'steamVRRoot',
        'privateConfigRoot',
        'privateLogRoot',
        'vrStartupPath'
    ) `
    -Message 'The resolved run configuration has an unexpected shape.'
Assert-Equal $configuration.privateConfigRoot ([IO.Path]::GetFullPath((Join-Path $configurationRunDirectory 'config'))) 'The private configuration path is not run-local.'
Assert-Equal $configuration.privateLogRoot ([IO.Path]::GetFullPath((Join-Path $configurationRunDirectory 'logs'))) 'The private log path is not run-local.'
Assert-Equal $configuration.vrStartupPath ([IO.Path]::GetFullPath((Join-Path $Context.SteamVRRoot 'bin\win64\vrstartup.exe'))) 'The startup path is not derived from the selected runtime.'
Complete-Test 'run configuration separates durable and derived state'

$pathBoundaryStateRoot = Join-Path $Context.Root 'path-boundary-state'
$outsideDirectory = Join-Path $pathBoundaryStateRoot 'outside-runs'
New-Item -ItemType Directory -Path $outsideDirectory -Force | Out-Null
'maintain' | Set-Content -LiteralPath (Join-Path $outsideDirectory 'marker.txt') -Encoding utf8NoBOM
$pathBoundaryResult = Stop-SteamVRNullDriverRun -RunId '..\outside-runs' -StateRoot $pathBoundaryStateRoot
Assert-True (-not $pathBoundaryResult.ok) 'A path-like value was accepted as a run ID.'
Assert-True (Test-Path -LiteralPath (Join-Path $outsideDirectory 'marker.txt')) 'A run ID resolved outside the runs directory.'
Complete-Test 'run IDs address direct run directories only'

$retainedStateRoot = Join-Path $Context.Root 'retained-state'
$retainedRunId = [Guid]::NewGuid().ToString('N')
$retainedRunDirectory = Join-Path (Join-Path $retainedStateRoot 'runs') $retainedRunId
New-Item -ItemType Directory -Path $retainedRunDirectory -Force | Out-Null
'{"phase":"expired","updatedUtc":"2026-01-01T00:00:00Z"}' |
    Set-Content -LiteralPath (Join-Path $retainedRunDirectory 'status.json') -Encoding utf8NoBOM
$retainedCheck = Invoke-SteamVRNullDriverCheck -SteamVRRoot $Context.SteamVRRoot -StateRoot $retainedStateRoot
Assert-True $retainedCheck.ok 'Check could not inspect retained run state.'
Assert-True $retainedCheck.canStart 'Retained run state claimed active ownership.'
Assert-Equal $retainedCheck.inactiveRuns.Count 1 'Check did not report the retained run.'
Assert-Equal $retainedCheck.inactiveRuns[0].runId $retainedRunId 'Check reported the wrong retained run ID.'
Assert-Equal $retainedCheck.inactiveRuns[0].phase 'expired' 'Check reported the wrong retained run phase.'
Complete-Test 'retained runs are observable without active ownership'

$newOwnerStart = & $module {
    param($RuntimeRoot, $StateRoot, $SupervisorScript)

    $originalStartDetachedSupervisor = (Get-Command Start-DetachedSupervisor -CommandType Function).ScriptBlock
    Set-Item -Path Function:Start-DetachedSupervisor -Value {
        param($SupervisorScriptPath, $RunId, $StateRoot)

        $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        [pscustomobject]@{
            runId = $RunId
            phase = 'ready'
            supervisor = Get-CurrentProcessRecord
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
} $Context.SteamVRRoot $retainedStateRoot $Context.SupervisorScript
Assert-True $newOwnerStart.ok 'A new owner did not accept a live ready supervisor.'
Assert-True (Test-Path -LiteralPath $retainedRunDirectory -PathType Container) 'A new start removed retained run state.'
$newOwnerRunDirectory = Join-Path (Join-Path $retainedStateRoot 'runs') $newOwnerStart.runId
$newOwnerCleanup = & $module {
    param($RunDirectory, $StateRoot)

    $configuration = Read-RunConfiguration -RunDirectory $RunDirectory
    Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $configuration
} $newOwnerRunDirectory $retainedStateRoot
Assert-True $newOwnerCleanup.complete 'The new-owner fixture did not release active ownership.'
Remove-Item -LiteralPath $newOwnerRunDirectory -Recurse -Force
$retainedStop = Stop-SteamVRNullDriverRun -RunId $retainedRunId -StateRoot $retainedStateRoot
Assert-True $retainedStop.ok 'Explicit stop did not remove retained run state.'
Assert-PropertySet `
    -Value $retainedStop `
    -Names @('ok', 'action', 'runId', 'run', 'error') `
    -Message 'Retained stop returned an unexpected result shape.'
Assert-True (-not (Test-Path -LiteralPath $retainedRunDirectory)) 'Explicit stop retained inactive run state.'
Assert-True (Test-Path -LiteralPath $retainedStateRoot -PathType Container) 'Retained stop removed the empty state namespace.'
Remove-Item -LiteralPath $retainedStateRoot -Recurse -Force
Complete-Test 'new starts preserve retained state for explicit removal'

$activeStatusStateRoot = Join-Path $Context.Root 'active-status-state'
$activeStatusRunId = [Guid]::NewGuid().ToString('N')
$activeStatusRunDirectory = Join-Path (Join-Path $activeStatusStateRoot 'runs') $activeStatusRunId
New-Item -ItemType Directory -Path $activeStatusRunDirectory -Force | Out-Null
$activeStatusConfiguration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $activeStatusRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $activeStatusRunId -SteamVRRoot $Context.SteamVRRoot)
[pscustomobject]@{ runId = $activeStatusRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $activeStatusStateRoot 'active-run.json') -Encoding utf8NoBOM
$currentSupervisor = & $module { Get-CurrentProcessRecord }
[pscustomobject]@{
    runId = $activeStatusRunId
    phase = 'ready'
    supervisor = $currentSupervisor
} |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $activeStatusRunDirectory 'status.json') -Encoding utf8NoBOM
$activeStatus = Get-SteamVRNullDriverStatus -RunId $activeStatusRunId -StateRoot $activeStatusStateRoot
Assert-True $activeStatus.ok 'Status could not inspect an active run.'
Assert-True $activeStatus.active 'Status did not report active ownership.'
Assert-True $activeStatus.supervisorAlive 'Status did not match the active supervisor identity.'
Assert-Equal $activeStatus.runtimeProcesses.Count 0 'Status reported runtime processes outside the fixture runtime.'
$activeStatusCleanup = & $module {
    param($RunDirectory, $StateRoot, $Configuration)
    Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
} $activeStatusRunDirectory $activeStatusStateRoot $activeStatusConfiguration
Assert-True $activeStatusCleanup.complete 'The active status fixture did not release ownership.'
Remove-Item -LiteralPath $activeStatusStateRoot -Recurse -Force
Complete-Test 'active status reports ownership and supervisor identity'

$retainedStatusStateRoot = Join-Path $Context.Root 'retained-status-state'
$retainedStatusRunId = [Guid]::NewGuid().ToString('N')
$retainedStatusRunDirectory = Join-Path (Join-Path $retainedStatusStateRoot 'runs') $retainedStatusRunId
New-Item -ItemType Directory -Path $retainedStatusRunDirectory -Force | Out-Null
$null = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $retainedStatusRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $retainedStatusRunId -SteamVRRoot $Context.SteamVRRoot)
[pscustomobject]@{
    runId = $retainedStatusRunId
    phase = 'failed'
    supervisor = [pscustomobject]@{ pid = 1 }
} |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $retainedStatusRunDirectory 'status.json') -Encoding utf8NoBOM
$retainedStatus = Get-SteamVRNullDriverStatus -RunId $retainedStatusRunId -StateRoot $retainedStatusStateRoot
Assert-True $retainedStatus.ok 'Status required a live supervisor for retained state.'
Assert-True (-not $retainedStatus.active) 'Status reported retained state as active.'
Assert-True (-not $retainedStatus.supervisorAlive) 'Status reported a retained supervisor as alive.'
Assert-Equal $retainedStatus.runtimeProcesses.Count 0 'Status attributed current runtime processes to retained state.'
Remove-Item -LiteralPath $retainedStatusStateRoot -Recurse -Force
Complete-Test 'retained status is independent of supervisor liveness'
