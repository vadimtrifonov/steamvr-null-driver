function Invoke-SteamVrHeadlessSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
    $configuration = Read-RunConfiguration -RunDirectory $runDirectory
    $launchPath = Join-Path $runDirectory 'launch.json'
    $handoffDeadline = (ConvertTo-UtcDateTime $configuration.createdUtc).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $launchPath -PathType Leaf) -and [DateTime]::UtcNow -lt $handoffDeadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
        throw 'The parent did not complete the detached-supervisor handoff.'
    }

    $launch = Read-JsonShared -Path $launchPath
    $supervisor = Get-CurrentProcessRecord
    if (-not (Test-ProcessRecordsMatch -First $supervisor -Second $launch.supervisor)) {
        throw 'The detached-supervisor identity does not match the launch record.'
    }
    $configuration.supervisor = $supervisor
    Write-JsonAtomic -Path (Join-Path $runDirectory 'run.json') -Value $configuration
    Update-ActiveRunRecord -StateRoot $StateRoot -RunId $RunId -Record ([ordered]@{
        schemaVersion = 1
        runId = $RunId
        runDirectory = $runDirectory
        createdUtc = $configuration.createdUtc
        supervisor = $supervisor
    })

    $state = [ordered]@{
        supervisor = $supervisor
        ready = $false
        cleanupComplete = $false
        reason = $null
        error = $null
        deadlineUtc = $configuration.deadlineUtc
        environment = [pscustomobject][ordered]@{
            VR_CONFIG_PATH = $configuration.configRoot
            VR_LOG_PATH = $configuration.logRoot
        }
        evidence = $null
        processes = @()
        cleanup = $null
    }
    $runtimeStartUtc = (ConvertTo-UtcDateTime $configuration.createdUtc).AddSeconds(-5)
    $leaseDeadline = ConvertTo-UtcDateTime $configuration.deadlineUtc
    $vrServerLog = Join-Path $configuration.logRoot 'vrserver.txt'
    $outcome = 'failed'

    try {
        Write-RunStatus -RunDirectory $runDirectory -RunId $RunId -Phase 'preflight' -Message 'Checking exclusive SteamVR ownership.' -State $state | Out-Null
        if (@(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot).Count -gt 0) {
            throw 'SteamVR started before the supervisor acquired the runtime. No configuration was changed.'
        }
        if ([DateTime]::UtcNow -ge $leaseDeadline) {
            $state.reason = 'lease-expired'
            $outcome = 'expired'
            throw 'The run lease expired before configuration started.'
        }

        Write-RunStatus -RunDirectory $runDirectory -RunId $RunId -Phase 'configuring' -Message 'Creating an isolated null-driver configuration.' -State $state | Out-Null
        $null = Initialize-PrivateHeadlessConfiguration `
            -SourceConfigRoot $configuration.sourceConfigRoot `
            -ConfigRoot $configuration.configRoot `
            -LogRoot $configuration.logRoot
        if (@(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot).Count -gt 0) {
            throw 'SteamVR started while the private configuration was prepared.'
        }

        $logCursor = New-TextCursor -Path $vrServerLog
        if ([DateTime]::UtcNow -ge $leaseDeadline) {
            $state.reason = 'lease-expired'
            $outcome = 'expired'
            throw 'The run lease expired before SteamVR startup.'
        }
        Write-RunStatus -RunDirectory $runDirectory -RunId $RunId -Phase 'starting' -Message 'Starting SteamVR.' -State $state | Out-Null
        [void](Start-VrStartupProcess `
            -Path $configuration.vrStartupPath `
            -ConfigRoot $configuration.configRoot `
            -LogRoot $configuration.logRoot)

        $startupDeadline = [DateTime]::UtcNow.AddSeconds([int]$configuration.startupTimeoutSeconds)
        do {
            if ([DateTime]::UtcNow -ge $leaseDeadline) {
                $state.reason = 'lease-expired'
                $outcome = 'expired'
                throw 'The run lease expired during SteamVR startup.'
            }

            $state.processes = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot -SinceUtc $runtimeStartUtc)
            if (@($state.processes | Where-Object { $_.name -eq 'steamvr_room_setup' }).Count -gt 0) {
                throw 'SteamVR Room Setup started during headless startup.'
            }
            $assessment = Get-VrLogAssessment -Text (Read-TextFromCursor -Path $vrServerLog -Cursor $logCursor)
            $hasServer = @($state.processes | Where-Object { $_.name -eq 'vrserver' }).Count -gt 0
            $hasCompositor = @($state.processes | Where-Object { $_.name -eq 'vrcompositor' }).Count -gt 0
            $assessment | Add-Member -MemberType NoteProperty -Name serverRunning -Value $hasServer
            $assessment | Add-Member -MemberType NoteProperty -Name compositorRunning -Value $hasCompositor
            $state.evidence = $assessment

            if ($assessment.modeViolation) {
                $drivers = @($assessment.unexpectedDrivers + $assessment.unexpectedHmdDrivers | Sort-Object -Unique) -join ', '
                throw "Unexpected SteamVR driver or HMD mode detected: $drivers"
            }
            if ($assessment.roomSetupDetected) {
                throw 'SteamVR Room Setup launched during headless startup.'
            }
            if ($assessment.ready -and $hasServer -and $hasCompositor) {
                break
            }
            Start-Sleep -Milliseconds 400
        } while ([DateTime]::UtcNow -lt $startupDeadline)

        if (-not $state.evidence.ready -or -not $state.evidence.serverRunning -or -not $state.evidence.compositorRunning) {
            throw 'SteamVR did not establish the expected null-only server and compositor before the startup timeout.'
        }

        $stabilityDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([DateTime]::UtcNow -lt $stabilityDeadline) {
            if ([DateTime]::UtcNow -ge $leaseDeadline) {
                $state.reason = 'lease-expired'
                $outcome = 'expired'
                throw 'The run lease expired during startup validation.'
            }
            Start-Sleep -Milliseconds 400
            $state.processes = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot -SinceUtc $runtimeStartUtc)
            $hasServer = @($state.processes | Where-Object { $_.name -eq 'vrserver' }).Count -gt 0
            $hasCompositor = @($state.processes | Where-Object { $_.name -eq 'vrcompositor' }).Count -gt 0
            $assessment = Get-VrLogAssessment -Text (Read-TextFromCursor -Path $vrServerLog -Cursor $logCursor)
            if ($assessment.modeViolation -or $assessment.roomSetupDetected -or -not $hasServer -or -not $hasCompositor) {
                throw 'SteamVR did not remain in the expected null-only server and compositor mode during startup validation.'
            }
        }

        $state.ready = $true
        $outcome = 'stopped'
        Write-RunStatus -RunDirectory $runDirectory -RunId $RunId -Phase 'ready' -Message 'SteamVR is running with the null HMD and compositor.' -State $state | Out-Null

        while ($true) {
            if (Test-Path -LiteralPath (Join-Path $runDirectory 'stop.request')) {
                $state.reason = 'requested'
                break
            }
            if ([DateTime]::UtcNow -ge $leaseDeadline) {
                $state.reason = 'lease-expired'
                $outcome = 'expired'
                break
            }

            $state.processes = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $configuration.steamVrRoot -SinceUtc $runtimeStartUtc)
            if (@($state.processes | Where-Object { $_.name -eq 'steamvr_room_setup' }).Count -gt 0) {
                throw 'SteamVR Room Setup started during the headless session.'
            }
            if (@($state.processes | Where-Object { $_.name -eq 'vrserver' }).Count -eq 0) {
                throw 'The owned vrserver process exited unexpectedly.'
            }
            if (@($state.processes | Where-Object { $_.name -eq 'vrcompositor' }).Count -eq 0) {
                throw 'The owned vrcompositor process exited unexpectedly.'
            }
            $assessment = Get-VrLogAssessment -Text (Read-TextFromCursor -Path $vrServerLog -Cursor $logCursor)
            $state.evidence = $assessment
            if ($assessment.modeViolation) {
                $drivers = @($assessment.unexpectedDrivers + $assessment.unexpectedHmdDrivers | Sort-Object -Unique) -join ', '
                throw "SteamVR changed to an unexpected driver or HMD mode: $drivers"
            }
            if ($assessment.roomSetupDetected) {
                throw 'SteamVR Room Setup launched during the headless session.'
            }
            Start-Sleep -Seconds 2
        }
    } catch {
        if ($state.reason -eq 'lease-expired') {
            $state.error = $null
            $outcome = 'expired'
        } else {
            $state.error = $_.Exception.Message
            $state.reason = if ($state.reason) { $state.reason } else { 'failure' }
            $outcome = 'failed'
        }
    } finally {
        $state.ready = $false
        $null = Write-RunStatusBestEffort -RunDirectory $runDirectory -RunId $RunId -Phase 'stopping' -Message 'Stopping the owned SteamVR runtime.' -State $state

        try {
            $cleanup = Invoke-RunCleanup -RunDirectory $runDirectory -StateRoot $StateRoot -Configuration $configuration
            $state.processes = if ($cleanup.processStops) { @($cleanup.processStops.remaining) } else { @() }
            $state.cleanup = [pscustomobject]@{
                processStops = $cleanup.processStops
                lockRemoved = $cleanup.lockRemoved
                privateConfigRoot = $cleanup.privateConfigRoot
                privateLogRoot = $cleanup.privateLogRoot
            }
            $state.cleanupComplete = [bool]$cleanup.complete
            if (-not $cleanup.complete) {
                $outcome = 'recovery-required'
                if (-not $state.error) {
                    $state.error = $cleanup.error
                }
            }
        } catch {
            $state.cleanupComplete = $false
            $outcome = 'recovery-required'
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
