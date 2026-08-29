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

    $supervisorPid = if ($State.supervisor) { [int]$State.supervisor.pid } else { 0 }
    [pscustomobject][ordered]@{
        runId = $RunId
        phase = $Phase
        message = $Message
        updatedUtc = Get-UtcText
        supervisorPid = $supervisorPid
        supervisor = $State.supervisor
        ready = [bool]$State.ready
        cleanupComplete = [bool]$State.cleanupComplete
        reason = $State.reason
        error = $State.error
        deadlineUtc = $State.deadlineUtc
        environment = $State.environment
        evidence = $State.evidence
        processes = @($State.processes | Where-Object { $null -ne $_ })
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
        Write-RunStatus -RunDirectory $RunDirectory -RunId $RunId -Phase $Phase -Message $Message -State $State | Out-Null
        $true
    } catch {
        Write-RunEvent -RunDirectory $RunDirectory -Message "status-write-failed - $($_.Exception.Message)"
        $false
    }
}

function Read-RunConfiguration {
    param([Parameter(Mandatory)][string]$RunDirectory)

    $configuration = Read-JsonShared -Path (Join-Path $RunDirectory 'run.json')
    Assert-RunId -RunId ([string]$configuration.runId)
    if ((Split-Path -Leaf $RunDirectory) -cne [string]$configuration.runId) {
        throw 'The run configuration ID does not match its directory.'
    }

    if ([int]$configuration.schemaVersion -ne 3) {
        throw 'The run configuration has an unsupported schema version.'
    }
    foreach ($name in @(
        'createdUtc', 'deadlineUtc', 'steamRoot', 'steamVrRoot',
        'sourceConfigRoot', 'privateConfigRoot', 'privateLogRoot', 'vrStartupPath'
    )) {
        if (-not [string]$configuration.$name) {
            throw "The run configuration is missing '$name'."
        }
    }
    $null = ConvertTo-UtcDateTime $configuration.createdUtc
    $null = ConvertTo-UtcDateTime $configuration.deadlineUtc

    $expectedSourceConfigRoot = ConvertTo-FullPath (Join-Path ([string]$configuration.steamRoot) 'config')
    $expectedPrivateConfigRoot = ConvertTo-FullPath (Join-Path $RunDirectory 'config')
    $expectedPrivateLogRoot = ConvertTo-FullPath (Join-Path $RunDirectory 'logs')
    if ((ConvertTo-FullPath ([string]$configuration.sourceConfigRoot)) -ne $expectedSourceConfigRoot) {
        throw 'The run configuration contains an unexpected source config root.'
    }
    if ((ConvertTo-FullPath ([string]$configuration.privateConfigRoot)) -ne $expectedPrivateConfigRoot) {
        throw 'The run configuration contains an unexpected private config path.'
    }
    if ((ConvertTo-FullPath ([string]$configuration.privateLogRoot)) -ne $expectedPrivateLogRoot) {
        throw 'The run configuration contains an unexpected private log path.'
    }
    if (-not (Test-PathWithin -Path ([string]$configuration.vrStartupPath) -Root ([string]$configuration.steamVrRoot))) {
        throw 'The run configuration contains a startup executable outside its SteamVR root.'
    }
    $configuration
}

function Get-ActiveRunRecord {
    param([Parameter(Mandatory)][string]$StateRoot)

    $path = Join-Path $StateRoot 'active-run.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $record = Read-JsonShared -Path $path
    Assert-RunId -RunId ([string]$record.runId)
    $expectedDirectory = Get-RunDirectory -StateRoot $StateRoot -RunId ([string]$record.runId)
    if ($record.runDirectory -and (ConvertTo-FullPath ([string]$record.runDirectory)) -ne $expectedDirectory) {
        throw 'The active-run lock points outside its expected run directory.'
    }
    $record
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
        [Parameter(Mandatory)]$Record
    )

    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $path = Join-Path $StateRoot 'active-run.json'
    $json = $Record | ConvertTo-Json -Depth 10
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Update-ActiveRunRecord {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Record
    )

    $active = Get-ActiveRunRecord -StateRoot $StateRoot
    if ($null -eq $active -or [string]$active.runId -cne $RunId) {
        throw 'The active-run lock was lost before supervisor handoff completed.'
    }
    Write-JsonAtomic -Path (Join-Path $StateRoot 'active-run.json') -Value $Record
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

function Get-RunSupervisor {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Configuration
    )

    if ($Configuration.supervisor) {
        return $Configuration.supervisor
    }
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

    if (Get-RunSupervisor -RunDirectory $RunDirectory -Configuration $Configuration) {
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
