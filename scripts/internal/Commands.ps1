function Invoke-SteamVrHeadlessCheck {
    [CmdletBinding()]
    param(
        [string]$SteamVrRoot,
        [Parameter(Mandatory)][string]$StateRoot
    )

    try {
        $paths = Resolve-SteamVrPaths -SteamVrRoot $SteamVrRoot
        $steamProcesses = @(Get-SteamClientProcesses)
        $runtimeProcesses = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $paths.steamVrRoot)
        $active = Get-ActiveRunRecord -StateRoot $StateRoot
        $inactiveRuns = @(Get-InactiveRunRecords -StateRoot $StateRoot -ActiveRun $active)

        [pscustomobject]@{
            ok = $true
            action = 'check'
            canStart = $steamProcesses.Count -gt 0 -and $runtimeProcesses.Count -eq 0 -and $null -eq $active
            paths = $paths
            steamProcesses = $steamProcesses
            activeRun = $active
            inactiveRuns = $inactiveRuns
            runtimeProcesses = $runtimeProcesses
        }
    } catch {
        [pscustomobject]@{
            ok = $false
            action = 'check'
            error = $_.Exception.Message
        }
    }
}

function Start-SteamVrHeadlessRun {
    [CmdletBinding()]
    param(
        [string]$SteamVrRoot,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$SupervisorScriptPath,
        [ValidateRange(1, 120)][int]$MaxDurationMinutes = 30
    )

    $check = Invoke-SteamVrHeadlessCheck -SteamVrRoot $SteamVrRoot -StateRoot $StateRoot
    if (-not $check.ok) {
        return [pscustomobject]@{ ok=$false; action='start'; error=$check.error; check=$check }
    }
    if (-not $check.canStart) {
        return [pscustomobject]@{
            ok = $false
            action = 'start'
            error = 'Preflight rejected the start. Steam must be running in this interactive session, SteamVR must be stopped, and no active run may exist.'
            check = $check
        }
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $runId
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $createdUtc = [DateTime]::UtcNow
    $deadlineUtc = $createdUtc.AddMinutes($MaxDurationMinutes)
    $configuration = [ordered]@{
        schemaVersion = 5
        runId = $runId
        createdUtc = $createdUtc.ToString('o')
        deadlineUtc = $deadlineUtc.ToString('o')
        steamVrRoot = $check.paths.steamVrRoot
    }
    Write-JsonAtomic -Path (Join-Path $runDirectory 'run.json') -Value $configuration

    $lockAcquired = $false
    $spawned = $false
    $prunedRuns = @()
    try {
        New-ActiveRunRecord -StateRoot $StateRoot -RunId $runId
        $lockAcquired = $true
        $prunedRuns = @(Remove-InactiveRunDirectories `
            -StateRoot $StateRoot `
            -ActiveRunId $runId `
            -ActiveRunDirectory $runDirectory)
        if ($prunedRuns.Count -gt 0) {
            Write-RunEvent -RunDirectory $runDirectory -Message "pruned-inactive - $($prunedRuns -join ', ')"
        }
        $supervisorPid = Start-DetachedSupervisor -SupervisorScriptPath $SupervisorScriptPath -RunId $runId -StateRoot $StateRoot
        $spawned = $true
        $identityDeadline = [DateTime]::UtcNow.AddSeconds(5)
        $supervisor = $null
        do {
            $supervisor = Get-ProcessRecordById -ProcessId $supervisorPid
            if ($supervisor) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $identityDeadline)
        if (-not $supervisor) {
            throw 'The detached supervisor started, but its process identity could not be recorded.'
        }
        Write-JsonAtomic -Path (Join-Path $runDirectory 'launch.json') -Value ([ordered]@{
            supervisor = $supervisor
        })
    } catch {
        $startError = $_.Exception.Message
        $cleanupError = $null
        if (-not $spawned) {
            try {
                $canRemoveRunDirectory = -not $lockAcquired
                if ($lockAcquired) {
                    $cleanupConfiguration = Read-RunConfiguration -RunDirectory $runDirectory
                    $cleanup = Invoke-RunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $cleanupConfiguration
                    $canRemoveRunDirectory = [bool]$cleanup.complete
                    if (-not $cleanup.complete) {
                        $cleanupError = $cleanup.error
                    }
                }
                if ($canRemoveRunDirectory) {
                    Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-EmptyStateDirectories -StateRoot $StateRoot
                }
            } catch {
                $cleanupError = $_.Exception.Message
            }
        }
        if ($cleanupError) {
            $startError = "$startError Pre-start cleanup also failed: $cleanupError"
        }
        return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; prunedRuns=$prunedRuns; error=$startError }
    }

    $clientDeadline = $createdUtc.AddSeconds($script:StartupTimeoutSeconds + 20)
    if ($clientDeadline -gt $deadlineUtc.AddSeconds(20)) {
        $clientDeadline = $deadlineUtc.AddSeconds(20)
    }
    $statusPath = Join-Path $runDirectory 'status.json'
    do {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $status = Read-JsonShared -Path $statusPath
                if ($status.phase -eq 'ready') {
                    return [pscustomobject]@{ ok=$true; action='start'; runId=$runId; prunedRuns=$prunedRuns; run=$status }
                }
                if (Test-RunPhaseTerminal -Phase ([string]$status.phase)) {
                    $statusError = if ($status.error) { [string]$status.error } else { "The run ended in phase '$($status.phase)' before readiness." }
                    return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; prunedRuns=$prunedRuns; error=$statusError; run=$status }
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $clientDeadline)

    [pscustomobject]@{
        ok = $false
        action = 'start'
        runId = $runId
        prunedRuns = $prunedRuns
        error = 'The client timed out waiting for the detached supervisor. Use status or stop with this run ID.'
    }
}

function Get-SteamVrHeadlessStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot
    )

    try {
        $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        $statusPath = Join-Path $runDirectory 'status.json'
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
            return [pscustomobject]@{ ok=$false; action='status'; runId=$RunId; error='The run status file was not found.' }
        }

        $configuration = Read-RunConfiguration -RunDirectory $runDirectory
        $supervisor = Get-RunSupervisor -RunDirectory $runDirectory
        [pscustomobject]@{
            ok = $true
            action = 'status'
            runId = $RunId
            supervisorAlive = Get-SupervisorAlive -Supervisor $supervisor
            runtimeProcesses = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot)
            run = Read-JsonShared -Path $statusPath
        }
    } catch {
        [pscustomobject]@{ ok=$false; action='status'; runId=$RunId; error=$_.Exception.Message }
    }
}

function Stop-SteamVrHeadlessRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot
    )

    try {
        $active = Get-ActiveRunRecord -StateRoot $StateRoot
        $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
            return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The run directory was not found.' }
        }

        if ($null -eq $active -or [string]$active.runId -cne $RunId) {
            $priorStatus = $null
            $statusPath = Join-Path $runDirectory 'status.json'
            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                try { $priorStatus = Read-JsonShared -Path $statusPath } catch {}
            }
            Remove-Item -LiteralPath $runDirectory -Recurse -Force
            Remove-EmptyStateDirectories -StateRoot $StateRoot
            return [pscustomobject]@{
                ok = $true
                action = 'stop'
                runId = $RunId
                result = 'removed inactive private journal'
                run = $priorStatus
                error = $null
            }
        }

        $configuration = Read-RunConfiguration -RunDirectory $runDirectory
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId $RunId -RunDirectory $runDirectory
        $supervisor = Get-RunSupervisor -RunDirectory $runDirectory
        if (-not $supervisor -and (Test-SupervisorHandoffPending -RunDirectory $runDirectory -Configuration $configuration)) {
            return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The detached-supervisor handoff is still pending. Retry stop after 15 seconds.' }
        }

        $status = $null
        if (Get-SupervisorAlive -Supervisor $supervisor) {
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'stop.request'), (Get-UtcText), [System.Text.UTF8Encoding]::new($false))
            $deadline = [DateTime]::UtcNow.AddSeconds($script:StopTimeoutSeconds)
            do {
                $statusPath = Join-Path $runDirectory 'status.json'
                if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                    try { $status = Read-JsonShared -Path $statusPath } catch {}
                }

                $currentActive = Get-ActiveRunRecord -StateRoot $StateRoot
                $ownsActiveLock = $null -ne $currentActive -and [string]$currentActive.runId -ceq $RunId
                if ($status -and [string]$status.phase -eq 'cleanup-required') {
                    break
                }
                if ($status -and (Test-RunPhaseClean -Phase ([string]$status.phase)) -and -not $ownsActiveLock) {
                    break
                }
                if ($currentActive -and [string]$currentActive.runId -cne $RunId) {
                    break
                }
                Start-Sleep -Milliseconds 300
            } while ([DateTime]::UtcNow -lt $deadline)

            $currentActive = Get-ActiveRunRecord -StateRoot $StateRoot
            $ownsActiveLock = $null -ne $currentActive -and [string]$currentActive.runId -ceq $RunId
            if ($ownsActiveLock -and (-not $status -or [string]$status.phase -ne 'cleanup-required')) {
                if (Get-SupervisorAlive -Supervisor $supervisor) {
                    return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The supervisor did not finish cleanup before the stop timeout.' }
                }
                $status = Invoke-DeadRunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration -Supervisor $supervisor
            }
        } else {
            $status = Invoke-DeadRunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration -Supervisor $supervisor
        }

        $currentActive = Get-ActiveRunRecord -StateRoot $StateRoot
        if ($currentActive -and [string]$currentActive.runId -cne $RunId) {
            return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; run=$status; error='Another run became active before stop completed.' }
        }

        $ownsActiveLock = $null -ne $currentActive -and [string]$currentActive.runId -ceq $RunId
        $cleanPhase = $status -and (Test-RunPhaseClean -Phase ([string]$status.phase))
        $verifiedWithoutFinalStatus = $false
        if (-not $ownsActiveLock -and -not $cleanPhase) {
            $verifiedWithoutFinalStatus = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot).Count -eq 0
        }
        $ok = -not $ownsActiveLock -and ($cleanPhase -or $verifiedWithoutFinalStatus)
        $error = if ($ok) {
            $null
        } elseif ($status -and $status.error) {
            [string]$status.error
        } else {
            'Cleanup did not reach a clean terminal state.'
        }
        $result = [pscustomobject]@{ ok=$ok; action='stop'; runId=$RunId; run=$status; error=$error }
        if ($ok) {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force
            Remove-EmptyStateDirectories -StateRoot $StateRoot
        }
        $result
    } catch {
        [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error=$_.Exception.Message }
    }
}

