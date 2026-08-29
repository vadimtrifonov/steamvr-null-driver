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
        privateConfigRoot = [string]$Configuration.configRoot
        privateLogRoot = [string]$Configuration.logRoot
    }
    $runtimeStartUtc = (ConvertTo-UtcDateTime $Configuration.createdUtc).AddSeconds(-5)

    try {
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId ([string]$Configuration.runId) -RunDirectory $RunDirectory
    } catch {
        $result.error = "Cleanup refused because the run does not own the active lock: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    try {
        $result.processStops = Stop-SteamVrRuntime `
            -SteamVrRoot ([string]$Configuration.steamVrRoot) `
            -SinceUtc $runtimeStartUtc `
            -ConfigRoot ([string]$Configuration.configRoot) `
            -LogRoot ([string]$Configuration.logRoot)
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
