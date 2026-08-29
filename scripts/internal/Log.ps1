function Read-VrLogText {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
    } catch [System.IO.FileNotFoundException] {
        return ''
    } catch [System.IO.DirectoryNotFoundException] {
        return ''
    }

    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true, 4096, $true)
        try {
            $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-VrLogAssessment {
    param([AllowEmptyString()][string]$Text)

    $loadedDrivers = @(
        [regex]::Matches($Text, "Loaded server driver\s+(?<driver>[^\s(]+)") |
            ForEach-Object { $_.Groups['driver'].Value } |
            Sort-Object -Unique
    )
    $activatingDrivers = @(
        [regex]::Matches($Text, "Driver\s+'(?<driver>[^']+)'\s+started activation of tracked device") |
            ForEach-Object { $_.Groups['driver'].Value } |
            Sort-Object -Unique
    )
    $activeHmdDrivers = @(
        [regex]::Matches($Text, 'Active HMD set to\s+(?<driver>[^\.\s]+)\.') |
            ForEach-Object { $_.Groups['driver'].Value }
    )
    $observedDrivers = @($loadedDrivers + $activatingDrivers | Sort-Object -Unique)
    $unexpectedDrivers = @($observedDrivers | Where-Object { $_ -ne 'null' })
    $unexpectedHmdDrivers = @($activeHmdDrivers | Where-Object { $_ -ne 'null' } | Sort-Object -Unique)
    $roomSetupDetected = $Text -match '(?i)(openvr\.tool\.steamvr_room_setup|steamvr_room_setup\.exe)'
    $directModeDetected = $Text -match '(?i)(\[Display\]\s+Enabling direct mode|Successfully set display visibility)'
    $nullLoaded = $loadedDrivers -contains 'null'
    $nullActive = $activeHmdDrivers.Count -gt 0 -and $activeHmdDrivers[-1] -eq 'null'

    [pscustomobject]@{
        ready = $nullLoaded -and $nullActive -and $unexpectedDrivers.Count -eq 0 -and $unexpectedHmdDrivers.Count -eq 0 -and -not $roomSetupDetected -and -not $directModeDetected
        nullDriverLoaded = $nullLoaded
        activeHmdDrivers = $activeHmdDrivers
        loadedDrivers = $loadedDrivers
        activatingDrivers = $activatingDrivers
        unexpectedDrivers = $unexpectedDrivers
        unexpectedHmdDrivers = $unexpectedHmdDrivers
        roomSetupDetected = $roomSetupDetected
        directModeDetected = $directModeDetected
        modeViolation = $unexpectedDrivers.Count -gt 0 -or $unexpectedHmdDrivers.Count -gt 0 -or $directModeDetected
    }
}
