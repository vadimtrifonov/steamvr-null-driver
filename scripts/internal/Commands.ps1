function Invoke-SteamVRNullDriverCheck {
    [CmdletBinding()]
    param(
        [string]$SteamVRRoot,
        [Parameter(Mandatory)][string]$StateRoot
    )

    try {
        $resolvedSteamVRRoot = Resolve-SteamVRRoot -SteamVRRoot $SteamVRRoot
        $steamProcesses = @(Get-SteamClientProcesses)
        $runtimeProcesses = @(Get-SteamVRRuntimeProcesses -SteamVRRoot $resolvedSteamVRRoot)
        $active = Get-ActiveRunRecord -StateRoot $StateRoot
        $inactiveRuns = @(Get-InactiveRunRecords -StateRoot $StateRoot -ActiveRun $active)

        [pscustomobject]@{
            ok = $true
            action = 'check'
            canStart = $steamProcesses.Count -gt 0 -and $runtimeProcesses.Count -eq 0 -and $null -eq $active
            steamVRRoot = $resolvedSteamVRRoot
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

function Start-SteamVRNullDriverRun {
    [CmdletBinding()]
    param(
        [string]$SteamVRRoot,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$SupervisorScriptPath,
        [ValidateRange(1, 120)][int]$MaxDurationMinutes = 30
    )

    $check = Invoke-SteamVRNullDriverCheck -SteamVRRoot $SteamVRRoot -StateRoot $StateRoot
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
    $createdUtc = [DateTime]::UtcNow
    $deadlineUtc = $createdUtc.AddMinutes($MaxDurationMinutes)
    $configuration = [ordered]@{
        schemaVersion = 6
        runId = $runId
        createdUtc = $createdUtc.ToString('o')
        deadlineUtc = $deadlineUtc.ToString('o')
        steamVRRoot = $check.steamVRRoot
    }

    $lockAcquired = $false
    $spawned = $false
    try {
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        Write-JsonAtomic -Path (Join-Path $runDirectory 'run.json') -Value $configuration
        New-ActiveRunRecord -StateRoot $StateRoot -RunId $runId
        $lockAcquired = $true
        Start-DetachedSupervisor -SupervisorScriptPath $SupervisorScriptPath -RunId $runId -StateRoot $StateRoot
        $spawned = $true
    } catch {
        $startError = $_.Exception.Message
        $cleanupError = $null
        if (-not $spawned) {
            try {
                $canRemoveRunDirectory = -not $lockAcquired
                if ($lockAcquired) {
                    [System.IO.File]::WriteAllText((Join-Path $runDirectory 'stop.request'), (Get-UtcText), [System.Text.UTF8Encoding]::new($false))
                    $cleanupConfiguration = Read-RunConfiguration -RunDirectory $runDirectory
                    $cleanup = Invoke-RunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $cleanupConfiguration
                    $canRemoveRunDirectory = [bool]$cleanup.complete
                    if (-not $cleanup.complete) {
                        $cleanupError = $cleanup.error
                    }
                }
                if ($canRemoveRunDirectory) {
                    Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
                }
            } catch {
                $cleanupError = $_.Exception.Message
            }
        }
        if ($cleanupError) {
            $startError = "$startError Pre-start cleanup also failed: $cleanupError"
        }
        $runStateRemoved = $false
        try {
            $runStateRemoved = -not (Test-Path -LiteralPath $runDirectory)
        } catch {}
        $failure = [ordered]@{ ok=$false; action='start' }
        if (-not $runStateRemoved) {
            $failure.runId = $runId
        }
        $failure.error = $startError
        return [pscustomobject]$failure
    }

    $clientDeadline = $createdUtc.AddSeconds($script:StartupTimeoutSeconds + 20)
    if ($clientDeadline -gt $deadlineUtc.AddSeconds(20)) {
        $clientDeadline = $deadlineUtc.AddSeconds(20)
    }
    $statusPath = Join-Path $runDirectory 'status.json'
    do {
        $status = $null
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            try {
                $status = Read-JsonShared -Path $statusPath
            } catch [System.IO.IOException] {
                $status = $null
            } catch {
                return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$_.Exception.Message }
            }
        }

        try {
            $currentActive = Get-ActiveRunRecord -StateRoot $StateRoot
        } catch {
            return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$_.Exception.Message }
        }
        $ownsActiveLock = $null -ne $currentActive -and [string]$currentActive.runId -ceq $runId
        if ($status -and [string]$status.phase -eq 'ready' -and $ownsActiveLock) {
            try {
                $supervisor = Get-StatusSupervisor -RunStatus $status
                if ($null -eq $supervisor) {
                    throw 'The ready run status has no supervisor identity.'
                }
                if (-not (Get-SupervisorAlive -Supervisor $supervisor)) {
                    return [pscustomobject]@{
                        ok = $false
                        action = 'start'
                        runId = $runId
                        error = 'The supervisor exited before the start command completed. Use stop with this run ID.'
                        run = $status
                    }
                }
            } catch {
                return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$_.Exception.Message; run=$status }
            }
            return [pscustomobject]@{ ok=$true; action='start'; runId=$runId; run=$status }
        }
        if ($status -and (Test-RunPhaseTerminal -Phase ([string]$status.phase))) {
            $statusError = if ($status.error) { [string]$status.error } else { "The run ended in phase '$($status.phase)' before readiness." }
            return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$statusError; run=$status }
        }
        if (-not $ownsActiveLock) {
            $statusError = if ($status -and $status.error) { [string]$status.error } else { 'The supervisor released the active lock before readiness.' }
            return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$statusError; run=$status }
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $clientDeadline)

    [pscustomobject]@{
        ok = $false
        action = 'start'
        runId = $runId
        error = 'The client timed out waiting for the detached supervisor. Use status or stop with this run ID.'
    }
}

function Get-SteamVRNullDriverStatus {
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
        $runStatus = Read-JsonShared -Path $statusPath
        $active = Get-ActiveRunRecord -StateRoot $StateRoot
        $isActive = $null -ne $active -and [string]$active.runId -ceq $RunId
        $supervisor = if ($isActive) { Get-StatusSupervisor -RunStatus $runStatus } else { $null }
        $supervisorAlive = if ($isActive) { Get-SupervisorAlive -Supervisor $supervisor } else { $false }
        $runtimeProcesses = if ($isActive) {
            @(Get-SteamVRRuntimeProcesses -SteamVRRoot $configuration.steamVRRoot)
        } else {
            @()
        }
        [pscustomobject]@{
            ok = $true
            action = 'status'
            runId = $RunId
            active = $isActive
            supervisorAlive = $supervisorAlive
            runtimeProcesses = $runtimeProcesses
            run = $runStatus
        }
    } catch {
        [pscustomobject]@{ ok=$false; action='status'; runId=$RunId; error=$_.Exception.Message }
    }
}

function Stop-SteamVRNullDriverRun {
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
            return [pscustomobject]@{
                ok = $true
                action = 'stop'
                runId = $RunId
                run = $priorStatus
                error = $null
            }
        }

        $configuration = Read-RunConfiguration -RunDirectory $runDirectory
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId $RunId -RunDirectory $runDirectory
        [System.IO.File]::WriteAllText((Join-Path $runDirectory 'stop.request'), (Get-UtcText), [System.Text.UTF8Encoding]::new($false))
        $statusPath = Join-Path $runDirectory 'status.json'
        $status = if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            Read-JsonShared -Path $statusPath
        } else {
            $null
        }
        $supervisor = Get-StatusSupervisor -RunStatus $status

        if (Get-SupervisorAlive -Supervisor $supervisor) {
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
                if (-not $ownsActiveLock) {
                    break
                }
                if (-not (Get-SupervisorAlive -Supervisor $supervisor)) {
                    break
                }
                Start-Sleep -Milliseconds 300
            } while ([DateTime]::UtcNow -lt $deadline)

            $currentActive = Get-ActiveRunRecord -StateRoot $StateRoot
            $ownsActiveLock = $null -ne $currentActive -and [string]$currentActive.runId -ceq $RunId
            if ($ownsActiveLock) {
                $supervisorAlive = Get-SupervisorAlive -Supervisor $supervisor
                if ($supervisorAlive -and (-not $status -or [string]$status.phase -ne 'cleanup-required')) {
                    return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The supervisor did not finish cleanup before the stop timeout.' }
                }
                if (-not $supervisorAlive) {
                    $status = Invoke-DeadRunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration -Supervisor $supervisor
                }
            }
        } else {
            $status = Invoke-DeadRunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration -Supervisor $supervisor
        }

        $postCleanupActive = Get-ActiveRunRecord -StateRoot $StateRoot
        if ($null -eq $postCleanupActive -and $supervisor) {
            $statusDeadline = [DateTime]::UtcNow.AddSeconds(2)
            do {
                $statusPath = Join-Path $runDirectory 'status.json'
                if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                    try { $status = Read-JsonShared -Path $statusPath } catch {}
                }
                if ($status -and (Test-RunPhaseTerminal -Phase ([string]$status.phase))) {
                    break
                }
                if (-not (Get-SupervisorAlive -Supervisor $supervisor)) {
                    break
                }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $statusDeadline)
        }

        $currentActive = Get-ActiveRunRecord -StateRoot $StateRoot
        if ($currentActive -and [string]$currentActive.runId -cne $RunId) {
            return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; run=$status; error='Another run became active before stop completed.' }
        }

        $ownsActiveLock = $null -ne $currentActive -and [string]$currentActive.runId -ceq $RunId
        $runtimeStopped = $false
        if (-not $ownsActiveLock) {
            $runtimeStopped = @(Get-SteamVRRuntimeProcesses -SteamVRRoot $configuration.steamVRRoot).Count -eq 0
        }
        $ok = -not $ownsActiveLock -and $runtimeStopped
        $error = if ($ok) {
            $null
        } elseif ($status -and $status.error) {
            [string]$status.error
        } elseif ($ownsActiveLock) {
            'Cleanup retained the active lock.'
        } else {
            'SteamVR processes remain under the selected runtime root.'
        }
        $result = [pscustomobject]@{ ok=$ok; action='stop'; runId=$RunId; run=$status; error=$error }
        if ($ok) {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force
        }
        $result
    } catch {
        [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error=$_.Exception.Message }
    }
}

