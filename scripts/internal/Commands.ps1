function Invoke-SteamVrHeadlessCheck {
    [CmdletBinding()]
    param(
        [string]$SteamRoot,
        [string]$SteamVrRoot,
        [Parameter(Mandatory)][string]$StateRoot
    )

    try {
        $paths = Resolve-SteamVrPaths -SteamRoot $SteamRoot -SteamVrRoot $SteamVrRoot
        $processes = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $paths.steamVrRoot)
        $active = Get-ActiveRunRecord -StateRoot $StateRoot
        $pendingRuns = @(Get-PendingRunRecords -StateRoot $StateRoot)
        $settingsValid = $false
        $settingsError = $null
        try {
            $null = [System.IO.File]::ReadAllText($paths.settingsPath) | ConvertFrom-Json
            $settingsValid = $true
        } catch {
            $settingsError = $_.Exception.Message
        }

        [pscustomobject]@{
            ok = $true
            action = 'check'
            canStart = $settingsValid -and $processes.Count -eq 0 -and $null -eq $active -and $pendingRuns.Count -eq 0
            paths = $paths
            activeRun = $active
            pendingRuns = $pendingRuns
            runtimeProcesses = $processes
            settingsValid = $settingsValid
            settingsError = $settingsError
            invariant = [pscustomobject]@{
                expectedDriver = 'null'
                compositorRequired = $true
                allowMultipleDrivers = $false
                rejectUnexpectedDriver = $true
                rejectRoomSetup = $true
            }
        }
    } catch {
        [pscustomobject]@{
            ok = $false
            action = 'check'
            error = $_.Exception.Message
        }
    }
}

function Start-DetachedSupervisor {
    param(
        [Parameter(Mandatory)][string]$EntryScriptPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $pwshPath = (Get-Process -Id $PID).Path
    $quote = {
        param([string]$Value)
        '"' + $Value.Replace('"', '\"') + '"'
    }
    $commandLine = @(
        & $quote $pwshPath
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy Bypass'
        '-File'
        & $quote (ConvertTo-FullPath $EntryScriptPath)
        'supervise'
        '-RunId'
        & $quote $RunId
        '-StateRoot'
        & $quote (ConvertTo-FullPath $StateRoot)
    ) -join ' '

    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)."
    }
    [int]$result.ProcessId
}

function Start-SteamVrHeadlessRun {
    [CmdletBinding()]
    param(
        [string]$SteamRoot,
        [string]$SteamVrRoot,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$EntryScriptPath,
        [ValidateRange(1, 1440)][int]$MaxDurationMinutes = 30,
        [ValidateRange(15, 300)][int]$StartupTimeoutSeconds = 90
    )

    $check = Invoke-SteamVrHeadlessCheck -SteamRoot $SteamRoot -SteamVrRoot $SteamVrRoot -StateRoot $StateRoot
    if (-not $check.ok) {
        return [pscustomobject]@{ ok=$false; action='start'; error=$check.error; check=$check }
    }
    if (-not $check.canStart) {
        return [pscustomobject]@{
            ok = $false
            action = 'start'
            error = 'Preflight rejected the start. SteamVR must be stopped, no unfinished run may exist, and the settings file must be valid JSON.'
            check = $check
        }
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $runId
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $createdUtc = [DateTime]::UtcNow
    $deadlineUtc = $createdUtc.AddMinutes($MaxDurationMinutes)
    $configuration = [ordered]@{
        schemaVersion = 1
        runId = $runId
        createdUtc = $createdUtc.ToString('o')
        deadlineUtc = $deadlineUtc.ToString('o')
        startupTimeoutSeconds = $StartupTimeoutSeconds
        steamRoot = $check.paths.steamRoot
        steamVrRoot = $check.paths.steamVrRoot
        configRoot = $check.paths.configRoot
        settingsPath = $check.paths.settingsPath
        vrStartupPath = $check.paths.vrStartupPath
        vrServerLog = $check.paths.vrServerLog
        supervisor = $null
    }
    Write-JsonAtomic -Path (Join-Path $runDirectory 'run.json') -Value $configuration

    $lockAcquired = $false
    $spawned = $false
    try {
        New-ActiveRunRecord -StateRoot $StateRoot -Record ([ordered]@{
            schemaVersion = 1
            runId = $runId
            runDirectory = $runDirectory
            createdUtc = $createdUtc.ToString('o')
            supervisor = $null
        })
        $lockAcquired = $true
        $supervisorPid = Start-DetachedSupervisor -EntryScriptPath $EntryScriptPath -RunId $runId -StateRoot $StateRoot
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
            schemaVersion = 1
            supervisor = $supervisor
        })
    } catch {
        $startError = $_.Exception.Message
        $cleanupError = $null
        if (-not $spawned) {
            try {
                $canRemoveRunDirectory = -not $lockAcquired
                if ($lockAcquired) {
                    $cleanup = Invoke-RunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration ([pscustomobject]$configuration)
                    $canRemoveRunDirectory = [bool]$cleanup.complete
                    if (-not $cleanup.complete) {
                        $cleanupError = $cleanup.error
                    }
                }
                if ($canRemoveRunDirectory) {
                    Remove-Item -LiteralPath $runDirectory -Recurse -Force
                    Remove-EmptyStateDirectories -StateRoot $StateRoot
                }
            } catch {
                $cleanupError = $_.Exception.Message
            }
        }
        if ($cleanupError) {
            $startError = "$startError Pre-start cleanup also failed: $cleanupError"
        }
        return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$startError }
    }

    $clientDeadline = $createdUtc.AddSeconds($StartupTimeoutSeconds + 20)
    if ($clientDeadline -gt $deadlineUtc.AddSeconds(20)) {
        $clientDeadline = $deadlineUtc.AddSeconds(20)
    }
    $statusPath = Join-Path $runDirectory 'status.json'
    do {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $status = Read-JsonShared -Path $statusPath
                if ($status.phase -eq 'ready') {
                    return [pscustomobject]@{ ok=$true; action='start'; runId=$runId; run=$status }
                }
                if ($status.phase -in @('failed', 'expired', 'recovery-required')) {
                    return [pscustomobject]@{ ok=$false; action='start'; runId=$runId; error=$status.error; run=$status }
                }
            } catch {}
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

function Get-SteamVrHeadlessStatus {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot
    )

    try {
        if (-not $RunId) {
            $active = Get-ActiveRunRecord -StateRoot $StateRoot
            if ($null -eq $active) {
                return [pscustomobject]@{ ok=$false; action='status'; error='No active run was found. Supply -RunId to inspect a retained completed run.' }
            }
            $RunId = [string]$active.runId
        }

        $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        $statusPath = Join-Path $runDirectory 'status.json'
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
            return [pscustomobject]@{ ok=$false; action='status'; runId=$RunId; error='The run status file was not found.' }
        }

        $configuration = Read-RunConfiguration -RunDirectory $runDirectory
        $supervisor = Get-RunSupervisor -RunDirectory $runDirectory -Configuration $configuration
        $runtimeStartUtc = (ConvertTo-UtcDateTime $configuration.createdUtc).AddSeconds(-5)
        [pscustomobject]@{
            ok = $true
            action = 'status'
            runId = $RunId
            supervisorAlive = Get-SupervisorAlive -Supervisor $supervisor
            runtimeProcesses = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot -SinceUtc $runtimeStartUtc)
            run = Read-JsonShared -Path $statusPath
        }
    } catch {
        [pscustomobject]@{ ok=$false; action='status'; runId=$RunId; error=$_.Exception.Message }
    }
}

function Stop-SteamVrHeadlessRun {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot,
        [ValidateRange(10, 180)][int]$TimeoutSeconds = 90
    )

    try {
        if (-not $RunId) {
            $active = Get-ActiveRunRecord -StateRoot $StateRoot
            if ($null -eq $active) {
                return [pscustomobject]@{ ok=$false; action='stop'; error='No active run was found.' }
            }
            $RunId = [string]$active.runId
        }

        $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
            return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The run directory was not found.' }
        }
        $configuration = Read-RunConfiguration -RunDirectory $runDirectory
        $statusPath = Join-Path $runDirectory 'status.json'
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            $completedStatus = Read-JsonShared -Path $statusPath
            if ([bool]$completedStatus.restored) {
                $active = Get-ActiveRunRecord -StateRoot $StateRoot
                if ($active -and [string]$active.runId -ceq $RunId) {
                    $null = Remove-ActiveRunRecord -StateRoot $StateRoot -RunId $RunId
                }
                Remove-Item -LiteralPath $runDirectory -Recurse -Force
                Remove-EmptyStateDirectories -StateRoot $StateRoot
                return [pscustomobject]@{ ok=$true; action='stop'; runId=$RunId; run=$completedStatus; error=$null }
            }
        }

        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId $RunId -RunDirectory $runDirectory
        $supervisor = Get-RunSupervisor -RunDirectory $runDirectory -Configuration $configuration
        if (-not $supervisor -and (Test-SupervisorHandoffPending -RunDirectory $runDirectory -Configuration $configuration)) {
            return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The detached-supervisor handoff is still pending. Retry stop after 15 seconds.' }
        }
        if ($supervisor) {
            $configuration.supervisor = $supervisor
        }
        $supervisorAlive = Get-SupervisorAlive -Supervisor $supervisor
        $status = $null

        if ($supervisorAlive) {
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'stop.request'), (Get-UtcText), [System.Text.UTF8Encoding]::new($false))
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            do {
                $statusPath = Join-Path $runDirectory 'status.json'
                if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                    $status = Read-JsonShared -Path $statusPath
                    if ($status.phase -in @('stopped', 'expired', 'failed', 'recovered', 'recovery-required')) {
                        break
                    }
                }
                Start-Sleep -Milliseconds 300
            } while ([DateTime]::UtcNow -lt $deadline)

            if (-not $status -or $status.phase -notin @('stopped', 'expired', 'failed', 'recovered', 'recovery-required')) {
                if (Get-SupervisorAlive -Supervisor $supervisor) {
                    return [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error='The supervisor did not finish cleanup before the stop timeout.' }
                }
                $status = Invoke-DeadRunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration
            }
        } else {
            $status = Invoke-DeadRunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration
        }

        $ok = [bool]$status.restored -and $status.phase -ne 'recovery-required'
        $result = [pscustomobject]@{ ok=$ok; action='stop'; runId=$RunId; run=$status; error=$status.error }
        if ($ok) {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force
            Remove-EmptyStateDirectories -StateRoot $StateRoot
        }
        $result
    } catch {
        [pscustomobject]@{ ok=$false; action='stop'; runId=$RunId; error=$_.Exception.Message }
    }
}

