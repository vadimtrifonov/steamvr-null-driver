[CmdletBinding()]
param([Parameter(Mandatory)]$Context)

$module = $Context.Module

$discovery = & $module {
    param($FixtureRoot, $SecondFixtureRoot)

    $original = (Get-Command Get-RegisteredSteamVrRoots -CommandType Function).ScriptBlock
    $script:fixtureSteamVrRoots = @($FixtureRoot)
    Set-Item -Path Function:Get-RegisteredSteamVrRoots -Value {
        @($script:fixtureSteamVrRoots)
    }
    try {
        $registered = Resolve-SteamVrRoot
        $explicit = Resolve-SteamVrRoot -SteamVrRoot $FixtureRoot
        $script:fixtureSteamVrRoots = @($FixtureRoot, $SecondFixtureRoot)
        $ambiguousRejected = $false
        try {
            $null = Resolve-SteamVrRoot
        } catch {
            $ambiguousRejected = $true
        }
        [pscustomobject]@{
            registered = $registered
            explicit = $explicit
            ambiguousRejected = $ambiguousRejected
        }
    } finally {
        Set-Item -Path Function:Get-RegisteredSteamVrRoots -Value $original
        Remove-Variable -Name fixtureSteamVrRoots -Scope Script -ErrorAction SilentlyContinue
    }
} $Context.SteamVrRoot $Context.SecondSteamVrRoot
Assert-Equal $discovery.registered ([IO.Path]::GetFullPath($Context.SteamVrRoot)) 'Registered discovery selected the wrong SteamVR root.'
Complete-Test 'registered SteamVR root is resolved'
Assert-Equal $discovery.explicit ([IO.Path]::GetFullPath($Context.SteamVrRoot)) 'Explicit discovery changed the selected SteamVR root.'
Complete-Test 'explicit SteamVR root is resolved'
Assert-True $discovery.ambiguousRejected 'Registered discovery selected one of multiple complete SteamVR roots.'
Complete-Test 'ambiguous registered roots require explicit selection'

$incompleteRuntime = Join-Path $Context.Root 'IncompleteSteamVR'
New-Item -ItemType Directory -Path (Join-Path $incompleteRuntime 'bin\win64') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $incompleteRuntime 'bin\win64\vrstartup.exe'), '')
$incompleteRejected = $false
try {
    $null = & $module { param($Root) Resolve-SteamVrRoot -SteamVrRoot $Root } $incompleteRuntime
} catch {
    $incompleteRejected = $true
}
Assert-True $incompleteRejected 'Startup accepted an incomplete SteamVR runtime.'
Complete-Test 'startup requires a complete null-driver runtime'

$cleanupRuntime = Join-Path $Context.Root 'CleanupSteamVR'
foreach ($relativePath in @(
    'bin\win64\vrserver.exe',
    'bin\win64\vrcompositor.exe',
    'bin\win64\vrmonitor.exe'
)) {
    $path = Join-Path $cleanupRuntime $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, '')
}
$layoutResult = & $module {
    param($Root)

    Assert-SteamVrCleanupLayout -SteamVrRoot $Root
    $startupAccepted = $true
    try {
        Assert-SteamVrRuntimeLayout -SteamVrRoot $Root
    } catch {
        $startupAccepted = $false
    }
    [pscustomobject]@{ startupAccepted = $startupAccepted }
} $cleanupRuntime
Assert-True (-not $layoutResult.startupAccepted) 'Startup accepted a runtime that only satisfies cleanup requirements.'
Complete-Test 'startup and cleanup use distinct runtime layouts'

$unrecognizedStateRoot = Join-Path $Context.Root 'unrecognized-cleanup-state'
$unrecognizedRunId = [Guid]::NewGuid().ToString('N')
$unrecognizedRunDirectory = Join-Path (Join-Path $unrecognizedStateRoot 'runs') $unrecognizedRunId
New-Item -ItemType Directory -Path $unrecognizedRunDirectory -Force | Out-Null
$unrecognizedConfiguration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $unrecognizedRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $unrecognizedRunId -SteamVrRoot $incompleteRuntime)
[pscustomobject]@{ runId = $unrecognizedRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $unrecognizedStateRoot 'active-run.json') -Encoding utf8NoBOM
$unrecognizedCleanup = & $module {
    param($RunDirectory, $StateRoot, $Configuration)
    Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
} $unrecognizedRunDirectory $unrecognizedStateRoot $unrecognizedConfiguration
Assert-True (-not $unrecognizedCleanup.complete) 'Cleanup accepted an unrecognized runtime root.'
Assert-True (Test-Path -LiteralPath (Join-Path $unrecognizedStateRoot 'active-run.json')) 'Cleanup removed ownership for an unrecognized runtime root.'
Complete-Test 'cleanup requires a recognizable runtime root'

$currentProcessRecord = & $module { Get-CurrentProcessRecord }
$inspectionResult = & $module {
    param($RuntimeRoot, $StateRoot, $ProcessRecord)

    Set-Item -Path Function:Get-CimInstance -Value { throw 'injected process query failure' }
    try {
        $check = Invoke-SteamVrHeadlessCheck -SteamVrRoot $RuntimeRoot -StateRoot $StateRoot
        $identityQueryFailed = $false
        try {
            $null = Get-SupervisorAlive -Supervisor $ProcessRecord
        } catch {
            $identityQueryFailed = $true
        }
        [pscustomobject]@{
            checkOk = $check.ok
            identityQueryFailed = $identityQueryFailed
        }
    } finally {
        Remove-Item -Path Function:Get-CimInstance -Force
    }
} $Context.SteamVrRoot (Join-Path $Context.Root 'query-failure-state') $currentProcessRecord
Assert-True (-not $inspectionResult.checkOk) 'A failed process query was treated as an idle runtime.'
Assert-True $inspectionResult.identityQueryFailed 'A failed identity query was treated as a stopped supervisor.'
Complete-Test 'process query failures do not imply an idle runtime'

$unreadableResult = & $module {
    param($RuntimeRoot)

    Set-Item -Path Function:Get-CimInstance -Value {
        param($ClassName, $Filter, $ErrorAction)
        [pscustomobject]@{
            ProcessId = 42
            Name = 'vrserver.exe'
            ExecutablePath = $null
            CreationDate = [DateTime]::UtcNow
        }
    }
    try {
        try {
            $null = Get-SteamVrRuntimeProcesses -SteamVrRoot $RuntimeRoot
            [pscustomobject]@{ failed = $false; error = $null }
        } catch {
            [pscustomobject]@{ failed = $true; error = $_.Exception.Message }
        }
    } finally {
        Remove-Item -Path Function:Get-CimInstance -Force
    }
} $Context.SteamVrRoot
Assert-True $unreadableResult.failed 'An unreadable SteamVR process was ignored.'
Assert-True ($unreadableResult.error -match 'no readable executable path') 'The unreadable-process error did not identify the missing path.'
Complete-Test 'unreadable SteamVR process blocks runtime inspection'

$transientProcessCount = & $module {
    param($RuntimeRoot)

    Set-Item -Path Function:Get-CimInstance -Value {
        param($ClassName, $Filter, $ErrorAction)
        if ($Filter) {
            return $null
        }
        [pscustomobject]@{
            ProcessId = 42
            Name = 'vrmonitor.exe'
            ExecutablePath = $null
            CreationDate = [DateTime]::UtcNow
        }
    }
    try {
        @(Get-SteamVrRuntimeProcesses -SteamVrRoot $RuntimeRoot).Count
    } finally {
        Remove-Item -Path Function:Get-CimInstance -Force
    }
} $Context.SteamVrRoot
Assert-Equal $transientProcessCount 0 'A process that exited during inspection remained in the runtime result.'
Complete-Test 'process exit during inspection is handled as stopped'

$ownershipStateRoot = Join-Path $Context.Root 'cleanup-ownership-state'
$ownedRunId = [Guid]::NewGuid().ToString('N')
$otherRunId = [Guid]::NewGuid().ToString('N')
$ownedRunDirectory = Join-Path (Join-Path $ownershipStateRoot 'runs') $ownedRunId
$otherRunDirectory = Join-Path (Join-Path $ownershipStateRoot 'runs') $otherRunId
New-Item -ItemType Directory -Path $ownedRunDirectory, $otherRunDirectory -Force | Out-Null
$ownedConfiguration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $ownedRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $ownedRunId -SteamVrRoot $Context.SteamVrRoot)
New-Item -ItemType Directory -Path $ownedConfiguration.privateConfigRoot -Force | Out-Null
$ownershipMarker = Join-Path $ownedConfiguration.privateConfigRoot 'marker.txt'
[System.IO.File]::WriteAllText($ownershipMarker, 'keep')
[pscustomobject]@{ runId = $otherRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $ownershipStateRoot 'active-run.json') -Encoding utf8NoBOM
$ownershipCleanup = & $module {
    param($RunDirectory, $StateRoot, $Configuration)
    Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
} $ownedRunDirectory $ownershipStateRoot $ownedConfiguration
Assert-True (-not $ownershipCleanup.complete) 'Cleanup completed without active ownership.'
Assert-True ($ownershipCleanup.error -match 'active lock') 'Cleanup did not report the ownership mismatch.'
Assert-True (Test-Path -LiteralPath $ownershipMarker) 'Cleanup changed private state without active ownership.'
$activeOwner = Get-Content -Raw -LiteralPath (Join-Path $ownershipStateRoot 'active-run.json') | ConvertFrom-Json
Assert-Equal $activeOwner.runId $otherRunId 'Cleanup changed another run ownership record.'
Complete-Test 'cleanup requires exact active ownership'

$shutdownStateRoot = Join-Path $Context.Root 'cleanup-order-state'
$shutdownRunId = [Guid]::NewGuid().ToString('N')
$shutdownRunDirectory = Join-Path (Join-Path $shutdownStateRoot 'runs') $shutdownRunId
New-Item -ItemType Directory -Path $shutdownRunDirectory -Force | Out-Null
$shutdownConfiguration = Write-FixtureRunConfiguration `
    -Module $module `
    -RunDirectory $shutdownRunDirectory `
    -Configuration (New-FixtureRunConfiguration -RunId $shutdownRunId -SteamVrRoot $Context.SteamVrRoot)
[pscustomobject]@{ runId = $shutdownRunId } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $shutdownStateRoot 'active-run.json') -Encoding utf8NoBOM
$originalStopSteamVrRuntime = & $module {
    (Get-Command Stop-SteamVrRuntime -CommandType Function).ScriptBlock
}
& $module {
    Set-Item -Path Function:script:Stop-SteamVrRuntime -Value {
        param($SteamVrRoot, $PrivateConfigRoot, $PrivateLogRoot)
        [pscustomobject]@{
            graceful = @()
            forced = @()
            errors = @()
            remaining = @([pscustomobject]@{ pid = 1; name = 'vrserver' })
            verifiedStopped = $false
            privateConfigRoot = $PrivateConfigRoot
            privateLogRoot = $PrivateLogRoot
        }
    }
}
try {
    $shutdownCleanup = & $module {
        param($RunDirectory, $StateRoot, $Configuration)
        Invoke-RunCleanup -RunDirectory $RunDirectory -StateRoot $StateRoot -Configuration $Configuration
    } $shutdownRunDirectory $shutdownStateRoot $shutdownConfiguration
    Assert-True (-not $shutdownCleanup.complete) 'Cleanup completed while a runtime process remained.'
    Assert-Equal $shutdownCleanup.processStops.privateConfigRoot $shutdownConfiguration.privateConfigRoot 'Cleanup did not use the run configuration for graceful shutdown.'
    Assert-Equal $shutdownCleanup.processStops.privateLogRoot $shutdownConfiguration.privateLogRoot 'Cleanup did not use the run logs for graceful shutdown.'
    Assert-True (Test-Path -LiteralPath (Join-Path $shutdownStateRoot 'active-run.json')) 'Cleanup removed ownership while a runtime process remained.'
} finally {
    & $module {
        param($Original)
        Set-Item -Path Function:script:Stop-SteamVrRuntime -Value $Original
    } $originalStopSteamVrRuntime
}
Complete-Test 'cleanup removes ownership after runtime shutdown'

$currentSupervisor = & $module { Get-CurrentProcessRecord }
$differentCreationTime = [pscustomobject]@{
    pid = $currentSupervisor.pid
    name = $currentSupervisor.name
    path = $currentSupervisor.path
    creationUtc = ([DateTime]::Parse([string]$currentSupervisor.creationUtc)).ToUniversalTime().AddMinutes(-1).ToString('o')
}
$identityAlive = & $module {
    param($Record)
    Get-SupervisorAlive -Supervisor $Record
} $differentCreationTime
Assert-True (-not $identityAlive) 'Process identity matched a PID with a different creation time.'
Complete-Test 'process identity includes creation time'
