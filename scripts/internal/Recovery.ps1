function Invoke-DeadRunCleanup {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$Configuration
    )

    $cleanup = Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
    $state = [ordered]@{
        supervisor = $Configuration.supervisor
        ready = $false
        cleanupComplete = [bool]$cleanup.complete
        reason = 'manual-recovery'
        error = $cleanup.error
        deadlineUtc = $Configuration.deadlineUtc
        environment = [pscustomobject][ordered]@{
            VR_CONFIG_PATH = $Configuration.configRoot
            VR_LOG_PATH = $Configuration.logRoot
        }
        evidence = $null
        processes = if ($cleanup.processStops) { @($cleanup.processStops.remaining) } else { @() }
        cleanup = [pscustomobject]@{
            processStops = $cleanup.processStops
            lockRemoved = $cleanup.lockRemoved
            privateConfigRoot = $cleanup.privateConfigRoot
            privateLogRoot = $cleanup.privateLogRoot
        }
    }
    $phase = if ($cleanup.complete) { 'recovered' } else { 'recovery-required' }
    $message = if ($cleanup.complete) { 'Stale run recovered.' } else { 'Stale run recovery was incomplete.' }
    $status = New-RunStatus -RunId $Configuration.runId -Phase $phase -Message $message -State $state
    $null = Write-RunStatusBestEffort -RunDirectory $RunDirectory -RunId $Configuration.runId -Phase $phase -Message $message -State $state
    $status
}

function Invoke-SteamVrHeadlessRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    $recovered = [System.Collections.Generic.List[object]]::new()
    $activeRuns = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $runsRoot = Join-Path $StateRoot 'runs'

    try {
        $active = Get-ActiveRunRecord -StateRoot $StateRoot
    } catch {
        return [pscustomobject]@{ ok=$false; action='recover'; recovered=@(); active=@(); errors=@([pscustomobject]@{runId=$null;error=$_.Exception.Message}) }
    }

    if (Test-Path -LiteralPath $runsRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory)) {
            try {
                Assert-RunId -RunId $directory.Name
                $configuration = Read-RunConfiguration -RunDirectory $directory.FullName
                $statusPath = Join-Path $directory.FullName 'status.json'
                $priorStatus = if (Test-Path -LiteralPath $statusPath -PathType Leaf) { Read-JsonShared -Path $statusPath } else { $null }
                $ownsActiveLock = $active -and [string]$active.runId -ceq [string]$configuration.runId

                if ($priorStatus -and [bool]$priorStatus.cleanupComplete) {
                    if ($ownsActiveLock) {
                        $null = Remove-ActiveRunRecord -StateRoot $StateRoot -RunId ([string]$configuration.runId)
                        $active = $null
                    }
                    Remove-Item -LiteralPath $directory.FullName -Recurse -Force
                    $recovered.Add([pscustomobject]@{ runId=$configuration.runId; result='removed completed journal' })
                    continue
                }

                if (-not $ownsActiveLock) {
                    $errors.Add([pscustomobject]@{
                        runId = $configuration.runId
                        error = 'The unfinished run does not own the active-run lock. Automatic recovery refused it.'
                    })
                    continue
                }

                $supervisor = Get-RunSupervisor -RunDirectory $directory.FullName -Configuration $configuration
                if ($supervisor -and (Get-SupervisorAlive -Supervisor $supervisor)) {
                    $activeRuns.Add([pscustomobject]@{ runId=$configuration.runId; result='supervisor is active' })
                    continue
                }
                if (-not $supervisor -and (Test-SupervisorHandoffPending -RunDirectory $directory.FullName -Configuration $configuration)) {
                    $activeRuns.Add([pscustomobject]@{ runId=$configuration.runId; result='supervisor handoff is pending' })
                    continue
                }
                if ($supervisor) {
                    $configuration.supervisor = $supervisor
                }

                $status = Invoke-DeadRunCleanup -RunDirectory $directory.FullName -StateRoot $StateRoot -Configuration $configuration
                if ($status.cleanupComplete) {
                    $active = $null
                    Remove-Item -LiteralPath $directory.FullName -Recurse -Force
                    $recovered.Add([pscustomobject]@{ runId=$configuration.runId; result='recovered' })
                } else {
                    $errors.Add([pscustomobject]@{ runId=$configuration.runId; error=$status.error })
                }
            } catch {
                $errors.Add([pscustomobject]@{ runId=$directory.Name; error=$_.Exception.Message })
            }
        }
    }

    try {
        $remainingActive = Get-ActiveRunRecord -StateRoot $StateRoot
        if ($remainingActive) {
            $activeDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId ([string]$remainingActive.runId)
            if (-not (Test-Path -LiteralPath $activeDirectory -PathType Container)) {
                $errors.Add([pscustomobject]@{ runId=$remainingActive.runId; error='The active-run lock has no run directory. Manual inspection is required.' })
            }
        }
    } catch {
        $errors.Add([pscustomobject]@{ runId=$null; error=$_.Exception.Message })
    }

    Remove-EmptyStateDirectories -StateRoot $StateRoot
    [pscustomobject]@{
        ok = $errors.Count -eq 0
        action = 'recover'
        recovered = @($recovered)
        active = @($activeRuns)
        errors = @($errors)
    }
}
