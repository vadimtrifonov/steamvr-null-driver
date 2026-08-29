function Start-DetachedSupervisor {
    param(
        [Parameter(Mandatory)][string]$SupervisorScriptPath,
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
        & $quote (ConvertTo-FullPath $SupervisorScriptPath)
        '-RunId'
        & $quote $RunId
        '-StateRoot'
        & $quote (ConvertTo-FullPath $StateRoot)
    ) -join ' '

    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) {
        throw "Win32_Process.Create failed with return value $($result.ReturnValue)."
    }
}

function Get-RunSupervisor {
    param([Parameter(Mandatory)][string]$RunDirectory)

    $statusPath = Join-Path $RunDirectory 'status.json'
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
        return $null
    }
    $status = Read-JsonShared -Path $statusPath
    $property = $status.PSObject.Properties['supervisor']
    if ($null -eq $property -or $null -eq $property.Value) {
        return $null
    }
    $supervisor = $property.Value
    if (-not $supervisor.pid -or -not $supervisor.path -or -not $supervisor.creationUtc) {
        throw 'The supervisor record in the run status is incomplete.'
    }
    $supervisor
}

function Get-SupervisorAlive {
    param([AllowNull()]$Supervisor)

    if ($null -eq $Supervisor -or -not $Supervisor.pid) {
        return $false
    }
    Test-ProcessRecordAlive -Record $Supervisor
}

function Assert-RunContinues {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][DateTime]$LeaseDeadline
    )

    if (Test-Path -LiteralPath (Join-Path $RunDirectory 'stop.request')) {
        $exception = [InvalidOperationException]::new('The run was stopped by request.')
        $exception.Data['RunOutcome'] = 'stopped'
        throw $exception
    }
    if ([DateTime]::UtcNow -ge $LeaseDeadline) {
        $exception = [TimeoutException]::new('The run lease expired.')
        $exception.Data['RunOutcome'] = 'expired'
        throw $exception
    }
}

function Invoke-SteamVrHeadlessSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
    $configuration = Read-RunConfiguration -RunDirectory $runDirectory
    $supervisor = Get-CurrentProcessRecord
    $state = [ordered]@{
        supervisor = $supervisor
        error = $null
        deadlineUtc = $configuration.deadlineUtc
        environment = Get-OpenVrEnvironment `
            -SteamVrRoot $configuration.steamVrRoot `
            -PrivateConfigRoot $configuration.privateConfigRoot `
            -PrivateLogRoot $configuration.privateLogRoot
        evidence = $null
        cleanup = $null
    }
    $leaseDeadline = ConvertTo-UtcDateTime $configuration.deadlineUtc
    $vrServerLog = Join-Path $configuration.privateLogRoot 'vrserver.txt'
    $serverRecord = $null
    $compositorRecord = $null
    $outcome = 'failed'

    Write-RunStatus -RunDirectory $runDirectory -RunId $RunId -Phase 'starting' -Message 'Preparing and starting SteamVR.' -State $state | Out-Null
    if (Test-Path -LiteralPath (Join-Path $runDirectory 'stop.request')) {
        return
    }
    $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId $RunId -RunDirectory $runDirectory

    try {
        Assert-RunContinues -RunDirectory $runDirectory -LeaseDeadline $leaseDeadline
        Assert-SteamVrRuntimeLayout -SteamVrRoot $configuration.steamVrRoot
        if (@(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot).Count -gt 0) {
            throw 'A SteamVR process started after the run reserved the runtime.'
        }

        Initialize-PrivateHeadlessConfiguration `
            -PrivateConfigRoot $configuration.privateConfigRoot `
            -PrivateLogRoot $configuration.privateLogRoot
        Assert-RunContinues -RunDirectory $runDirectory -LeaseDeadline $leaseDeadline
        if (@(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot).Count -gt 0) {
            throw 'A SteamVR process started while the private configuration was prepared.'
        }

        [void](Start-VrStartupProcess `
            -Path $configuration.vrStartupPath `
            -SteamVrRoot $configuration.steamVrRoot `
            -PrivateConfigRoot $configuration.privateConfigRoot `
            -PrivateLogRoot $configuration.privateLogRoot)

        $startupDeadline = [DateTime]::UtcNow.AddSeconds($script:StartupTimeoutSeconds)
        $readySince = $null
        $startupValidated = $false
        do {
            Assert-RunContinues -RunDirectory $runDirectory -LeaseDeadline $leaseDeadline
            $runtimeProcesses = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot)
            if (@($runtimeProcesses | Where-Object { $_.name -eq 'steamvr_room_setup' }).Count -gt 0) {
                throw 'SteamVR Room Setup started during headless startup.'
            }

            $assessment = Get-VrLogAssessment -Text (Read-VrLogText -Path $vrServerLog)
            if ($assessment.directModeDetected) {
                throw 'SteamVR attempted to enable Direct Display Mode.'
            }
            if ($assessment.modeViolation) {
                $drivers = @($assessment.unexpectedDrivers + $assessment.unexpectedHmdDrivers | Sort-Object -Unique) -join ', '
                throw "Unexpected SteamVR driver or HMD mode detected: $drivers"
            }
            if ($assessment.roomSetupDetected) {
                throw 'SteamVR Room Setup launched during headless startup.'
            }

            $servers = @($runtimeProcesses | Where-Object { $_.name -eq 'vrserver' })
            $compositors = @($runtimeProcesses | Where-Object { $_.name -eq 'vrcompositor' })
            if ($servers.Count -gt 1 -or $compositors.Count -gt 1) {
                throw 'More than one SteamVR server or compositor process started.'
            }

            if ($null -eq $readySince) {
                $serverRunning = $servers.Count -eq 1
                $compositorRunning = $compositors.Count -eq 1
                $assessment | Add-Member -MemberType NoteProperty -Name serverRunning -Value $serverRunning
                $assessment | Add-Member -MemberType NoteProperty -Name compositorRunning -Value $compositorRunning
                $state.evidence = $assessment
                if ($assessment.ready -and $serverRunning -and $compositorRunning) {
                    $serverRecord = $servers[0]
                    $compositorRecord = $compositors[0]
                    $readySince = [DateTime]::UtcNow
                }
            } else {
                $serverStable = $servers.Count -eq 1 -and (Test-ProcessRecordsMatch -First $servers[0] -Second $serverRecord)
                $compositorStable = $compositors.Count -eq 1 -and (Test-ProcessRecordsMatch -First $compositors[0] -Second $compositorRecord)
                $assessment | Add-Member -MemberType NoteProperty -Name serverRunning -Value $serverStable
                $assessment | Add-Member -MemberType NoteProperty -Name compositorRunning -Value $compositorStable
                $state.evidence = $assessment
                if (-not $assessment.ready -or -not $serverStable -or -not $compositorStable) {
                    throw 'SteamVR did not remain in the expected null-only server and compositor mode during startup validation.'
                }
                if (([DateTime]::UtcNow - $readySince).TotalSeconds -ge 5) {
                    $startupValidated = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 400
        } while ([DateTime]::UtcNow -lt $startupDeadline)

        if (-not $startupValidated) {
            if ($readySince) {
                throw 'SteamVR did not remain stable for five seconds before the startup timeout.'
            }
            throw 'SteamVR did not establish the expected null-only server and compositor before the startup timeout.'
        }

        Write-RunStatus -RunDirectory $runDirectory -RunId $RunId -Phase 'ready' -Message 'SteamVR is running with the null HMD and compositor.' -State $state | Out-Null

        while ($true) {
            Assert-RunContinues -RunDirectory $runDirectory -LeaseDeadline $leaseDeadline
            if (-not (Test-ProcessRecordAlive -Record $serverRecord)) {
                throw 'The owned vrserver process exited unexpectedly.'
            }
            if (-not (Test-ProcessRecordAlive -Record $compositorRecord)) {
                throw 'The owned vrcompositor process exited unexpectedly.'
            }
            Start-Sleep -Seconds 2
        }
    } catch {
        $controlOutcome = $_.Exception.Data['RunOutcome']
        if ($controlOutcome) {
            $state.error = $null
            $outcome = [string]$controlOutcome
        } else {
            $state.error = $_.Exception.Message
            $outcome = 'failed'
        }
    } finally {
        $null = Write-RunStatusBestEffort -RunDirectory $runDirectory -RunId $RunId -Phase 'stopping' -Message 'Stopping the owned SteamVR runtime.' -State $state

        try {
            $cleanup = Invoke-RunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration
            $state.cleanup = [pscustomobject]@{
                processStops = $cleanup.processStops
                lockRemoved = $cleanup.lockRemoved
            }
            if (-not $cleanup.complete) {
                $outcome = 'cleanup-required'
                if (-not $state.error) {
                    $state.error = $cleanup.error
                }
            }
        } catch {
            $outcome = 'cleanup-required'
            if (-not $state.error) {
                $state.error = $_.Exception.Message
            }
        }

        $message = switch ($outcome) {
            'stopped' { 'SteamVR stopped and the active lock was removed.' }
            'expired' { 'The run lease expired. SteamVR stopped and the active lock was removed.' }
            'failed' { 'The run failed. Owned resources stopped and the active lock was removed.' }
            default { 'Automatic cleanup requires review.' }
        }
        $null = Write-RunStatusBestEffort -RunDirectory $runDirectory -RunId $RunId -Phase $outcome -Message $message -State $state
    }
}
