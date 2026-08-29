function Invoke-DeadRunCleanup {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$Configuration,
        [AllowNull()]$Supervisor
    )

    $cleanup = Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
    $state = [ordered]@{
        supervisor = $Supervisor
        ready = $false
        cleanupComplete = [bool]$cleanup.complete
        reason = 'manual-recovery'
        error = $cleanup.error
        deadlineUtc = $Configuration.deadlineUtc
        environment = Get-OpenVrEnvironment `
            -PrivateConfigRoot $Configuration.privateConfigRoot `
            -PrivateLogRoot $Configuration.privateLogRoot
        evidence = $null
        cleanup = [pscustomobject]@{
            processStops = $cleanup.processStops
            lockRemoved = $cleanup.lockRemoved
        }
    }
    $phase = if ($cleanup.complete) { 'recovered' } else { 'recovery-required' }
    $message = if ($cleanup.complete) { 'Stale run recovered.' } else { 'Stale run recovery was incomplete.' }
    $status = Write-RunStatusBestEffort -RunDirectory $RunDirectory -RunId $Configuration.runId -Phase $phase -Message $message -State $state
    if ($null -eq $status) {
        $status = New-RunStatus -RunId $Configuration.runId -Phase $phase -Message $message -State $state
    }
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

    if ($active) {
        $activeRunId = [string]$active.runId
        try {
            $activeDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $activeRunId
            if (-not (Test-Path -LiteralPath $activeDirectory -PathType Container)) {
                throw 'The active-run lock has no run directory. Manual inspection is required.'
            }

            $configuration = Read-RunConfiguration -RunDirectory $activeDirectory
            $statusPath = Join-Path $activeDirectory 'status.json'
            $priorStatus = if (Test-Path -LiteralPath $statusPath -PathType Leaf) { Read-JsonShared -Path $statusPath } else { $null }

            if ($priorStatus -and [bool]$priorStatus.cleanupComplete) {
                $null = Remove-ActiveRunRecord -StateRoot $StateRoot -RunId $activeRunId
                $active = $null
                Remove-Item -LiteralPath $activeDirectory -Recurse -Force
                $recovered.Add([pscustomobject]@{ runId=$activeRunId; result='removed completed active journal' })
            } else {
                $supervisor = Get-RunSupervisor -RunDirectory $activeDirectory
                if ($supervisor -and (Get-SupervisorAlive -Supervisor $supervisor)) {
                    $activeRuns.Add([pscustomobject]@{ runId=$activeRunId; result='supervisor is active' })
                } elseif (-not $supervisor -and (Test-SupervisorHandoffPending -RunDirectory $activeDirectory -Configuration $configuration)) {
                    $activeRuns.Add([pscustomobject]@{ runId=$activeRunId; result='supervisor handoff is pending' })
                } else {
                    $status = Invoke-DeadRunCleanup -RunDirectory $activeDirectory -StateRoot $StateRoot -Configuration $configuration -Supervisor $supervisor
                    if ($status.cleanupComplete) {
                        $active = $null
                        Remove-Item -LiteralPath $activeDirectory -Recurse -Force
                        $recovered.Add([pscustomobject]@{ runId=$activeRunId; result='recovered active run' })
                    } else {
                        $errors.Add([pscustomobject]@{ runId=$activeRunId; error=$status.error })
                    }
                }
            }
        } catch {
            $errors.Add([pscustomobject]@{ runId=$activeRunId; error=$_.Exception.Message })
        }
    }

    if (Test-Path -LiteralPath $runsRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory)) {
            if ($active -and $directory.Name -ceq [string]$active.runId) {
                continue
            }
            try {
                Assert-RunId -RunId $directory.Name
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force
                $recovered.Add([pscustomobject]@{ runId=$directory.Name; result='removed inactive private journal' })
            } catch {
                $errors.Add([pscustomobject]@{ runId=$directory.Name; error=$_.Exception.Message })
            }
        }
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
