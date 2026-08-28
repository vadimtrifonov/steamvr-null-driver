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
        files = [pscustomobject]@{ restored=$false; attempted=$false; files=@() }
        lockRemoved = $false
    }
    $runtimeStartUtc = (ConvertTo-UtcDateTime $Configuration.createdUtc).AddSeconds(-5)

    try {
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId ([string]$Configuration.runId) -RunDirectory $RunDirectory
    } catch {
        $result.error = "Cleanup refused because the run does not own the active lock: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    try {
        $result.processStops = Stop-SteamVrRuntime -SteamVrRoot ([string]$Configuration.steamVrRoot) -SinceUtc $runtimeStartUtc
    } catch {
        $result.error = "SteamVR process inspection or shutdown failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    if (-not $result.processStops.verifiedStopped) {
        $result.error = 'SteamVR processes remain. Protected files were not restored.'
        return [pscustomobject]$result
    }

    try {
        $null = Assert-ActiveRunOwnership -StateRoot $StateRoot -RunId ([string]$Configuration.runId) -RunDirectory $RunDirectory
    } catch {
        $result.error = "File restoration refused because the run lost the active lock: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $manifestPath = Join-Path $RunDirectory 'protected-files.json'
    $configurationStartedPath = Join-Path $RunDirectory 'configuration-started'
    try {
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $expectedPaths = Get-ProtectedConfigPaths -ConfigRoot ([string]$Configuration.configRoot)
            $fileResult = Restore-ProtectedFileManifest -ManifestPath $manifestPath -ExpectedPaths $expectedPaths
            $fileResult | Add-Member -MemberType NoteProperty -Name attempted -Value $true
            $result.files = $fileResult
        } elseif (Test-Path -LiteralPath $configurationStartedPath -PathType Leaf) {
            throw 'The protected-file manifest is missing after configuration started.'
        } else {
            $result.files = [pscustomobject]@{
                restored = $true
                attempted = $false
                files = @()
                note = 'No configuration change started.'
            }
        }
    } catch {
        $result.error = "Protected-file restoration failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    if (-not $result.files.restored) {
        $result.error = 'One or more protected files could not be restored.'
        return [pscustomobject]$result
    }

    try {
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
