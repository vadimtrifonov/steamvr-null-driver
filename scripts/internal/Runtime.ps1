$script:CanonicalSteamVrProcessNames = @(
    'steamvr_room_setup',
    'vrdashboard',
    'vrwebhelper',
    'vrmonitor',
    'vrcompositor',
    'vrserver',
    'vrstartup'
)

function Resolve-SteamVrPaths {
    param(
        [string]$SteamRoot,
        [string]$SteamVrRoot
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($SteamRoot) {
        $candidates.Add((ConvertTo-FullPath $SteamRoot))
    } else {
        foreach ($path in @('C:\Steam', 'C:\Program Files (x86)\Steam', 'C:\Program Files\Steam')) {
            if (Test-Path -LiteralPath $path) {
                $candidates.Add((ConvertTo-FullPath $path))
            }
        }
        foreach ($registryPath in @(
            'HKCU:\SOFTWARE\Valve\Steam',
            'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
            'HKLM:\SOFTWARE\Valve\Steam'
        )) {
            try {
                $installPath = (Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction Stop).InstallPath
                if ($installPath) {
                    $candidates.Add((ConvertTo-FullPath $installPath))
                }
            } catch {}
        }
    }

    $valid = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($candidates | Sort-Object -Unique)) {
        $runtimeRoot = if ($SteamVrRoot) {
            ConvertTo-FullPath $SteamVrRoot
        } else {
            Join-Path $candidate 'steamapps\common\SteamVR'
        }
        $configPath = Join-Path $candidate 'config\steamvr.vrsettings'
        $startupPath = Join-Path $runtimeRoot 'bin\win64\vrstartup.exe'
        if ((Test-Path -LiteralPath $configPath -PathType Leaf) -and (Test-Path -LiteralPath $startupPath -PathType Leaf)) {
            $valid.Add([pscustomobject]@{
                steamRoot = $candidate
                steamVrRoot = ConvertTo-FullPath $runtimeRoot
                configRoot = Join-Path $candidate 'config'
                settingsPath = $configPath
                vrStartupPath = $startupPath
                vrServerLog = Join-Path $candidate 'logs\vrserver.txt'
            })
        }
    }

    if ($valid.Count -eq 0) {
        throw 'No Steam root contained both config\steamvr.vrsettings and the SteamVR vrstartup executable. Supply -SteamRoot and, if needed, -SteamVrRoot.'
    }
    if ($valid.Count -gt 1) {
        $roots = @($valid | ForEach-Object { $_.steamRoot }) -join ', '
        throw "More than one valid Steam installation was found: $roots. Supply -SteamRoot explicitly."
    }
    $valid[0]
}

function ConvertTo-ProcessRecord {
    param([Parameter(Mandatory)]$Process)

    if (-not $Process.ExecutablePath) {
        throw "Process $($Process.ProcessId) has no readable executable path."
    }
    if (-not $Process.CreationDate) {
        throw "Process $($Process.ProcessId) has no readable creation time."
    }

    [pscustomobject]@{
        pid = [int]$Process.ProcessId
        name = [System.IO.Path]::GetFileNameWithoutExtension([string]$Process.Name)
        path = ConvertTo-FullPath ([string]$Process.ExecutablePath)
        creationUtc = ([DateTime]$Process.CreationDate).ToUniversalTime().ToString('o')
    }
}

function Get-ProcessRecordById {
    param([Parameter(Mandatory)][int]$ProcessId)

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if ($null -eq $process) {
        return $null
    }
    ConvertTo-ProcessRecord -Process $process
}

function Get-CurrentProcessRecord {
    $record = Get-ProcessRecordById -ProcessId $PID
    if ($null -eq $record) {
        throw 'The current process identity could not be read.'
    }
    $record
}

function Resolve-ProcessForRuntimeInspection {
    param([Parameter(Mandatory)]$Process)

    if ($Process.ExecutablePath) {
        return $Process
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$Process.Name)
    if ($script:CanonicalSteamVrProcessNames -notcontains $name) {
        return $null
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($Process.ProcessId)" -ErrorAction Stop
        if ($null -eq $current) {
            return $null
        }
        if ($current.ExecutablePath) {
            return $current
        }
        $currentName = [System.IO.Path]::GetFileNameWithoutExtension([string]$current.Name)
        if ($script:CanonicalSteamVrProcessNames -notcontains $currentName) {
            return $null
        }
        if ($attempt -lt 2) {
            Start-Sleep -Milliseconds 50
        }
    }

    throw "SteamVR process $($Process.ProcessId) ('$name') has no readable executable path."
}

function Get-SteamVrRuntimeProcesses {
    param(
        [Parameter(Mandatory)][string]$SteamVrRoot,
        [DateTime]$SinceUtc = [DateTime]::MinValue
    )

    $root = ConvertTo-FullPath $SteamVrRoot
    $items = [System.Collections.Generic.List[object]]::new()
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach ($process in $processes) {
        $process = Resolve-ProcessForRuntimeInspection -Process $process
        if ($null -eq $process) {
            continue
        }
        $path = ConvertTo-FullPath ([string]$process.ExecutablePath)
        if (-not (Test-PathWithin -Path $path -Root $root)) {
            continue
        }
        $record = ConvertTo-ProcessRecord -Process $process
        if ((ConvertTo-UtcDateTime $record.creationUtc) -ge $SinceUtc) {
            $items.Add($record)
        }
    }
    @($items | Sort-Object pid)
}

function Test-ProcessRecordsMatch {
    param(
        [Parameter(Mandatory)]$First,
        [Parameter(Mandatory)]$Second
    )

    [int]$First.pid -eq [int]$Second.pid -and
        (ConvertTo-FullPath ([string]$First.path)) -eq (ConvertTo-FullPath ([string]$Second.path)) -and
        [Math]::Abs(((ConvertTo-UtcDateTime $First.creationUtc) - (ConvertTo-UtcDateTime $Second.creationUtc)).TotalMilliseconds) -lt 10
}

function Test-ProcessRecordAlive {
    param([Parameter(Mandatory)]$Record)

    $current = Get-ProcessRecordById -ProcessId ([int]$Record.pid)
    if ($null -eq $current) {
        return $false
    }
    Test-ProcessRecordsMatch -First $current -Second $Record
}

function Stop-SteamVrRuntime {
    param(
        [Parameter(Mandatory)][string]$SteamVrRoot,
        [Parameter(Mandatory)][DateTime]$SinceUtc
    )

    $graceful = [System.Collections.Generic.List[string]]::new()
    $forced = [System.Collections.Generic.List[string]]::new()
    $stopErrors = [System.Collections.Generic.List[string]]::new()
    $records = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot -SinceUtc $SinceUtc)
    if ($records.Count -eq 0) {
        return [pscustomobject]@{
            graceful = @()
            forced = @()
            errors = @()
            remaining = @()
            verifiedStopped = $true
        }
    }

    $monitor = @($records | Where-Object { $_.name -eq 'vrmonitor' } | Select-Object -First 1)
    if ($monitor.Count -gt 0) {
        try {
            $info = [System.Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $monitor[0].path
            $info.WorkingDirectory = Split-Path -Parent $monitor[0].path
            $info.UseShellExecute = $false
            [void]$info.ArgumentList.Add('vrmonitor://quit')
            [void][System.Diagnostics.Process]::Start($info)
            $graceful.Add("vrmonitor-protocol:$($monitor[0].pid)")
        } catch {
            $stopErrors.Add("Graceful shutdown request failed: $($_.Exception.Message)")
        }
    }

    if ($monitor.Count -gt 0) {
        $gracefulDeadline = [DateTime]::UtcNow.AddSeconds(12)
        while ([DateTime]::UtcNow -lt $gracefulDeadline) {
            if (@(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot -SinceUtc $SinceUtc).Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 400
        }
    }

    $stopOrder = $script:CanonicalSteamVrProcessNames
    for ($pass = 0; $pass -lt 2; $pass++) {
        $records = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot -SinceUtc $SinceUtc)
        foreach ($name in $stopOrder) {
            foreach ($record in @($records | Where-Object { $_.name -eq $name })) {
                try {
                    if (Test-ProcessRecordAlive -Record $record) {
                        Stop-Process -Id $record.pid -Force -ErrorAction Stop
                        $forced.Add("$($record.name):$($record.pid)")
                    }
                } catch {
                    $stopErrors.Add("Could not stop $($record.name):$($record.pid): $($_.Exception.Message)")
                }
            }
        }
        foreach ($record in @($records | Where-Object { $stopOrder -notcontains $_.name })) {
            try {
                if (Test-ProcessRecordAlive -Record $record) {
                    Stop-Process -Id $record.pid -Force -ErrorAction Stop
                    $forced.Add("$($record.name):$($record.pid)")
                }
            } catch {
                $stopErrors.Add("Could not stop $($record.name):$($record.pid): $($_.Exception.Message)")
            }
        }
        Start-Sleep -Milliseconds 500
    }

    $remaining = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot -SinceUtc $SinceUtc)
    [pscustomobject]@{
        graceful = @($graceful)
        forced = @($forced)
        errors = @($stopErrors)
        remaining = $remaining
        verifiedStopped = $remaining.Count -eq 0
    }
}

function Start-VrStartupProcess {
    param([Parameter(Mandatory)][string]$Path)

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Path
    $info.WorkingDirectory = Split-Path -Parent $Path
    $info.UseShellExecute = $false
    [System.Diagnostics.Process]::Start($info)
}
