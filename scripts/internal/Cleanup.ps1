function Invoke-RunCleanup {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$Configuration
    )

    $result = [ordered]@{
        complete = $false
        error = $null
        processStops = $null
        lockRemoved = $false
    }

    try {
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId ([string]$Configuration.runId) -RunDirectory $RunDirectory
    } catch {
        $result.error = "Cleanup refused because the run does not own the active lock: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    try {
        $result.processStops = Stop-SteamVrRuntime `
            -SteamVrRoot ([string]$Configuration.steamVrRoot) `
            -PrivateConfigRoot ([string]$Configuration.privateConfigRoot) `
            -PrivateLogRoot ([string]$Configuration.privateLogRoot)
    } catch {
        $result.error = "SteamVR process inspection or shutdown failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    if (-not $result.processStops.verifiedStopped) {
        $result.error = 'SteamVR processes remain. The active lock and private run state were retained.'
        return [pscustomobject]$result
    }

    try {
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId ([string]$Configuration.runId) -RunDirectory $RunDirectory
        $result.lockRemoved = Remove-ActiveRunRecord -StateRoot $StateRoot -RunId ([string]$Configuration.runId)
    } catch {
        $result.error = "The active-run lock could not be removed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    if (-not $result.lockRemoved) {
        $result.error = 'The active-run lock still exists.'
        return [pscustomobject]$result
    }

    $result.complete = $true
    [pscustomobject]$result
}

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
        reason = 'stale-supervisor'
        error = $cleanup.error
        deadlineUtc = $Configuration.deadlineUtc
        environment = Get-OpenVrEnvironment `
            -SteamVrRoot $Configuration.steamVrRoot `
            -PrivateConfigRoot $Configuration.privateConfigRoot `
            -PrivateLogRoot $Configuration.privateLogRoot
        evidence = $null
        cleanup = [pscustomobject]@{
            processStops = $cleanup.processStops
            lockRemoved = $cleanup.lockRemoved
        }
    }
    $phase = if ($cleanup.complete) { 'stopped' } else { 'cleanup-required' }
    $message = if ($cleanup.complete) { 'The stale run stopped.' } else { 'Stale run cleanup was incomplete.' }
    $status = Write-RunStatusBestEffort -RunDirectory $RunDirectory -RunId $Configuration.runId -Phase $phase -Message $message -State $state
    if ($null -eq $status) {
        $status = New-RunStatus -RunId $Configuration.runId -Phase $phase -Message $message -State $state
    }
    $status
}
