function Read-StreamBytes {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Count
    )

    $buffer = [byte[]]::new($Count)
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $total = 0
    while ($total -lt $Count) {
        $read = $Stream.Read($buffer, $total, $Count - $total)
        if ($read -eq 0) {
            return $null
        }
        $total += $read
    }
    Write-Output -NoEnumerate $buffer
}

function New-TextCursor {
    param([Parameter(Mandatory)][string]$Path)

    $cursor = [pscustomobject]@{
        offset = 0L
        reset = $false
        anchorOffset = 0L
        anchorLength = 0
        anchorHash = $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $cursor
    }

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
    } catch [System.IO.FileNotFoundException] {
        return $cursor
    } catch [System.IO.DirectoryNotFoundException] {
        return $cursor
    }

    try {
        $cursor.offset = $stream.Length
        if ($cursor.offset -gt 0) {
            $cursor.anchorLength = [int][Math]::Min(128L, [long]$cursor.offset)
            $cursor.anchorOffset = [long]$cursor.offset - $cursor.anchorLength
            $anchor = Read-StreamBytes -Stream $stream -Offset $cursor.anchorOffset -Count $cursor.anchorLength
            if ($null -eq $anchor) {
                throw 'The SteamVR log changed while its cursor was created.'
            }
            $cursor.anchorHash = Get-ByteHash -Bytes $anchor
        }
        $cursor
    } finally {
        $stream.Dispose()
    }
}

function Read-TextFromCursor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Cursor
    )

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
    } catch [System.IO.FileNotFoundException] {
        if ([long]$Cursor.offset -gt 0) {
            $Cursor.offset = 0L
            $Cursor.reset = $true
        }
        return ''
    } catch [System.IO.DirectoryNotFoundException] {
        if ([long]$Cursor.offset -gt 0) {
            $Cursor.offset = 0L
            $Cursor.reset = $true
        }
        return ''
    }

    try {
        $reset = $stream.Length -lt [long]$Cursor.offset
        if (-not $reset -and [long]$Cursor.offset -gt 0) {
            $anchor = Read-StreamBytes -Stream $stream -Offset ([long]$Cursor.anchorOffset) -Count ([int]$Cursor.anchorLength)
            $reset = $null -eq $anchor -or (Get-ByteHash -Bytes $anchor) -cne [string]$Cursor.anchorHash
        }
        if ($reset) {
            $Cursor.offset = 0L
            $Cursor.reset = $true
        }

        [void]$stream.Seek([long]$Cursor.offset, [System.IO.SeekOrigin]::Begin)
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
    $nullLoaded = $loadedDrivers -contains 'null'
    $nullActive = $activeHmdDrivers.Count -gt 0 -and $activeHmdDrivers[-1] -eq 'null'

    [pscustomobject]@{
        ready = $nullLoaded -and $nullActive -and $unexpectedDrivers.Count -eq 0 -and $unexpectedHmdDrivers.Count -eq 0 -and -not $roomSetupDetected
        nullDriverLoaded = $nullLoaded
        activeHmdDrivers = $activeHmdDrivers
        loadedDrivers = $loadedDrivers
        activatingDrivers = $activatingDrivers
        unexpectedDrivers = $unexpectedDrivers
        unexpectedHmdDrivers = $unexpectedHmdDrivers
        roomSetupDetected = $roomSetupDetected
        modeViolation = $unexpectedDrivers.Count -gt 0 -or $unexpectedHmdDrivers.Count -gt 0
    }
}
