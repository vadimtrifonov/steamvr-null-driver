function Write-RunEvent {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        $path = Join-Path $RunDirectory 'events.log'
        $line = "[$(Get-UtcText)] $Message$([Environment]::NewLine)"
        [System.IO.File]::AppendAllText($path, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

function New-RunStatus {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)]$State
    )

    [pscustomobject][ordered]@{
        runId = $RunId
        phase = $Phase
        message = $Message
        updatedUtc = Get-UtcText
        supervisor = $State.supervisor
        ready = [bool]$State.ready
        cleanupComplete = [bool]$State.cleanupComplete
        reason = $State.reason
        error = $State.error
        deadlineUtc = $State.deadlineUtc
        environment = $State.environment
        evidence = $State.evidence
        cleanup = $State.cleanup
    }
}

function Write-RunStatus {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)]$State
    )

    $status = New-RunStatus -RunId $RunId -Phase $Phase -Message $Message -State $State
    Write-JsonAtomic -Path (Join-Path $RunDirectory 'status.json') -Value $status
    Write-RunEvent -RunDirectory $RunDirectory -Message "$Phase - $Message"
    [pscustomobject]$status
}

function Write-RunStatusBestEffort {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)]$State
    )

    try {
        Write-RunStatus -RunDirectory $RunDirectory -RunId $RunId -Phase $Phase -Message $Message -State $State
    } catch {
        Write-RunEvent -RunDirectory $RunDirectory -Message "status-write-failed - $($_.Exception.Message)"
        $null
    }
}

function Read-RunConfiguration {
    param([Parameter(Mandatory)][string]$RunDirectory)

    $stored = Read-JsonShared -Path (Join-Path $RunDirectory 'run.json')
    Assert-RunId -RunId ([string]$stored.runId)
    if ((Split-Path -Leaf $RunDirectory) -cne [string]$stored.runId) {
        throw 'The run configuration ID does not match its directory.'
    }
    if ([int]$stored.schemaVersion -ne 5) {
        throw 'The run configuration has an unsupported schema version.'
    }
    foreach ($name in @('createdUtc', 'deadlineUtc', 'startupTimeoutSeconds', 'steamVrRoot')) {
        if (-not [string]$stored.$name) {
            throw "The run configuration is missing '$name'."
        }
    }

    $createdUtc = ConvertTo-UtcDateTime $stored.createdUtc
    $deadlineUtc = ConvertTo-UtcDateTime $stored.deadlineUtc
    $startupTimeoutSeconds = [int]$stored.startupTimeoutSeconds
    if ($deadlineUtc -le $createdUtc) {
        throw 'The run deadline must be later than its creation time.'
    }
    if ($startupTimeoutSeconds -lt 15 -or $startupTimeoutSeconds -gt 300) {
        throw 'The run startup timeout is outside the supported range.'
    }

    $steamVrRoot = ConvertTo-FullPath ([string]$stored.steamVrRoot)
    Assert-SteamVrRuntimeLayout -SteamVrRoot $steamVrRoot
    [pscustomobject][ordered]@{
        schemaVersion = 5
        runId = [string]$stored.runId
        createdUtc = $createdUtc.ToString('o')
        deadlineUtc = $deadlineUtc.ToString('o')
        startupTimeoutSeconds = $startupTimeoutSeconds
        steamVrRoot = $steamVrRoot
        privateConfigRoot = ConvertTo-FullPath (Join-Path $RunDirectory 'config')
        privateLogRoot = ConvertTo-FullPath (Join-Path $RunDirectory 'logs')
        vrStartupPath = ConvertTo-FullPath (Join-Path $steamVrRoot 'bin\win64\vrstartup.exe')
    }
}

function Get-ActiveRunRecord {
    param([Parameter(Mandatory)][string]$StateRoot)

    $path = Join-Path $StateRoot 'active-run.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $record = Read-JsonShared -Path $path
    Assert-RunId -RunId ([string]$record.runId)
    [pscustomobject]@{
        runId = [string]$record.runId
        runDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId ([string]$record.runId)
    }
}

function Assert-ActiveRunOwnership {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RunId,
        [string]$RunDirectory
    )

    Assert-RunId -RunId $RunId
    $active = Get-ActiveRunRecord -StateRoot $StateRoot
    if ($null -eq $active) {
        throw 'The run does not own an active-run lock.'
    }
    if ([string]$active.runId -cne $RunId) {
        throw 'The active-run lock belongs to another run.'
    }
    if ($RunDirectory) {
        $expectedDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId $RunId
        if ((ConvertTo-FullPath $RunDirectory) -ne $expectedDirectory) {
            throw 'The cleanup directory does not match the active-run lock.'
        }
    }
    $active
}

function New-ActiveRunRecord {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    Assert-RunId -RunId $RunId
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $path = Join-Path $StateRoot 'active-run.json'
    $json = @{ runId=$RunId } | ConvertTo-Json
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Remove-ActiveRunRecord {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $path = Join-Path $StateRoot 'active-run.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return $true
    }

    $active = Get-ActiveRunRecord -StateRoot $StateRoot
    if ([string]$active.runId -cne $RunId) {
        throw 'The active-run lock belongs to another run.'
    }
    Remove-Item -LiteralPath $path -Force
    -not (Test-Path -LiteralPath $path)
}

function Remove-EmptyStateDirectories {
    param([Parameter(Mandatory)][string]$StateRoot)

    $runsRoot = Join-Path $StateRoot 'runs'
    if ((Test-Path -LiteralPath $runsRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $runsRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $runsRoot -Force
    }
    if ((Test-Path -LiteralPath $StateRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $StateRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $StateRoot -Force
    }
}

function Get-InactiveRunRecords {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowNull()]$ActiveRun
    )

    $runsRoot = Join-Path $StateRoot 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
        return @()
    }

    $activeRunId = if ($ActiveRun) { [string]$ActiveRun.runId } else { $null }
    @(
        foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -Force)) {
            if ($activeRunId -and $directory.Name -ceq $activeRunId) {
                continue
            }

            $record = [ordered]@{
                runId = $directory.Name
                phase = 'unknown'
                cleanupComplete = $null
                updatedUtc = $null
                error = $null
            }
            $statusPath = Join-Path $directory.FullName 'status.json'
            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                try {
                    $status = Read-JsonShared -Path $statusPath
                    if ($status.phase) { $record.phase = [string]$status.phase }
                    if ($null -ne $status.PSObject.Properties['cleanupComplete']) {
                        $record.cleanupComplete = [bool]$status.cleanupComplete
                    }
                    if ($status.updatedUtc) { $record.updatedUtc = [string]$status.updatedUtc }
                } catch {
                    $record.error = $_.Exception.Message
                }
            }
            [pscustomobject]$record
        }
    )
}

function Remove-InactiveRunDirectories {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ActiveRunId,
        [Parameter(Mandatory)][string]$ActiveRunDirectory
    )

    $null = Assert-ActiveRunOwnership `
        -StateRoot $StateRoot `
        -RunId $ActiveRunId `
        -RunDirectory $ActiveRunDirectory
    $runsRoot = Join-Path $StateRoot 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
        return @()
    }

    @(
        foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -Force)) {
            if ($directory.Name -ceq $ActiveRunId) {
                continue
            }
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            $directory.Name
        }
    )
}

function Get-RunSupervisor {
    param([Parameter(Mandatory)][string]$RunDirectory)

    $launchPath = Join-Path $RunDirectory 'launch.json'
    if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
        return $null
    }
    $launch = Read-JsonShared -Path $launchPath
    if (-not $launch.supervisor.pid -or -not $launch.supervisor.path -or -not $launch.supervisor.creationUtc) {
        throw 'The supervisor launch record is incomplete.'
    }
    $launch.supervisor
}

function Test-SupervisorHandoffPending {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Configuration
    )

    if (Get-RunSupervisor -RunDirectory $RunDirectory) {
        return $false
    }
    [DateTime]::UtcNow -lt (ConvertTo-UtcDateTime $Configuration.createdUtc).AddSeconds(15)
}

function Get-SupervisorAlive {
    param([AllowNull()]$Supervisor)

    if ($null -eq $Supervisor -or -not $Supervisor.pid) {
        return $false
    }
    Test-ProcessRecordAlive -Record $Supervisor
}
