$script:CanonicalSteamVrProcessNames = @(
    'steamvr_room_setup',
    'vrdashboard',
    'vrwebhelper',
    'vrmonitor',
    'vrcompositor',
    'vrserver',
    'vrstartup'
)

function Get-RegisteredSteamRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKCU:\SOFTWARE\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($propertyName in @('SteamPath', 'InstallPath')) {
                $property = $properties.PSObject.Properties[$propertyName]
                if ($property -and $property.Value) {
                    $roots.Add((ConvertTo-FullPath ([string]$property.Value)))
                }
            }
            $steamExe = $properties.PSObject.Properties['SteamExe']
            if ($steamExe -and $steamExe.Value) {
                $roots.Add((ConvertTo-FullPath (Split-Path -Parent ([string]$steamExe.Value))))
            }
        } catch {}
    }
    @($roots | Sort-Object -Unique)
}

function Get-RegisteredSteamVrRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 250820',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 250820',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 250820'
    )) {
        try {
            $installLocation = (Get-ItemProperty -LiteralPath $registryPath -Name InstallLocation -ErrorAction Stop).InstallLocation
            if ($installLocation) {
                $roots.Add((ConvertTo-FullPath ([string]$installLocation)))
            }
        } catch {}
    }
    @($roots | Sort-Object -Unique)
}

function Resolve-SteamVrPaths {
    param(
        [string]$SteamRoot,
        [string]$SteamVrRoot
    )

    if ($SteamVrRoot) {
        $runtimeRoot = ConvertTo-FullPath $SteamVrRoot
    } else {
        $registeredRoots = @(Get-RegisteredSteamVrRoots | Where-Object {
            Test-Path -LiteralPath (Join-Path $_ 'bin\win64\vrstartup.exe') -PathType Leaf
        })
        if ($registeredRoots.Count -gt 1) {
            throw "More than one registered SteamVR installation was found: $($registeredRoots -join ', '). Supply -SteamVrRoot."
        }

        if ($registeredRoots.Count -eq 1) {
            $runtimeRoot = $registeredRoots[0]
        } else {
            $steamRoots = @(if ($SteamRoot) {
                ConvertTo-FullPath $SteamRoot
            } else {
                Get-RegisteredSteamRoots
            })
            $runtimeRoots = @($steamRoots | ForEach-Object {
                $candidate = ConvertTo-FullPath (Join-Path $_ 'steamapps\common\SteamVR')
                if (Test-Path -LiteralPath (Join-Path $candidate 'bin\win64\vrstartup.exe') -PathType Leaf) {
                    $candidate
                }
            } | Sort-Object -Unique)
            if ($runtimeRoots.Count -eq 0) {
                throw 'SteamVR was not found in its app registration or under a registered Steam root. Supply -SteamVrRoot.'
            }
            if ($runtimeRoots.Count -gt 1) {
                throw "More than one SteamVR installation was found under Steam roots: $($runtimeRoots -join ', '). Supply -SteamVrRoot."
            }
            $runtimeRoot = $runtimeRoots[0]
        }
    }

    $startupPath = ConvertTo-FullPath (Join-Path $runtimeRoot 'bin\win64\vrstartup.exe')
    if (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) {
        throw 'The selected SteamVR root has no bin\win64\vrstartup.exe.'
    }

    [pscustomobject]@{
        steamVrRoot = ConvertTo-FullPath $runtimeRoot
        vrStartupPath = $startupPath
    }
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
    param([Parameter(Mandatory)][string]$SteamVrRoot)

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
        $items.Add((ConvertTo-ProcessRecord -Process $process))
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
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    $graceful = [System.Collections.Generic.List[string]]::new()
    $forced = [System.Collections.Generic.List[string]]::new()
    $stopErrors = [System.Collections.Generic.List[string]]::new()
    $records = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot)
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
            $info = New-OpenVrProcessInfo `
                -Path $monitor[0].path `
                -PrivateConfigRoot $PrivateConfigRoot `
                -PrivateLogRoot $PrivateLogRoot
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
            if (@(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot).Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 400
        }
    }

    $stopOrder = $script:CanonicalSteamVrProcessNames
    for ($pass = 0; $pass -lt 2; $pass++) {
        $records = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot)
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

    $remaining = @(Get-SteamVrRuntimeProcesses -SteamVrRoot $SteamVrRoot)
    [pscustomobject]@{
        graceful = @($graceful)
        forced = @($forced)
        errors = @($stopErrors)
        remaining = $remaining
        verifiedStopped = $remaining.Count -eq 0
    }
}

function New-OpenVrProcessInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    $environment = Get-OpenVrEnvironment -PrivateConfigRoot $PrivateConfigRoot -PrivateLogRoot $PrivateLogRoot
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Path
    $info.WorkingDirectory = Split-Path -Parent $Path
    $info.UseShellExecute = $false
    foreach ($property in $environment.PSObject.Properties) {
        $info.Environment[$property.Name] = [string]$property.Value
    }
    $info
}

function Start-VrStartupProcess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    $info = New-OpenVrProcessInfo `
        -Path $Path `
        -PrivateConfigRoot $PrivateConfigRoot `
        -PrivateLogRoot $PrivateLogRoot
    [System.Diagnostics.Process]::Start($info)
}
