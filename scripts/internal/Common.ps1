function Get-UtcText {
    [DateTime]::UtcNow.ToString('o')
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime
    }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }

    [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

function ConvertTo-FullPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        return $fullPath.TrimEnd('\', '/')
    }
    $fullPath
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = (ConvertTo-FullPath $Path) + '\'
    $fullRoot = (ConvertTo-FullPath $Root) + '\'
    $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RunId {
    param([Parameter(Mandatory)][string]$RunId)

    if ($RunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'A run ID must be exactly 32 lowercase hexadecimal characters.'
    }
}

function Get-RunDirectory {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    Assert-RunId -RunId $RunId
    $runsRoot = ConvertTo-FullPath (Join-Path $StateRoot 'runs')
    $runDirectory = ConvertTo-FullPath (Join-Path $runsRoot $RunId)
    if ((Split-Path -Parent $runDirectory) -ne $runsRoot) {
        throw 'The resolved run directory is not a direct child of the runs directory.'
    }
    $runDirectory
}

function Read-JsonShared {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    )
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true, 4096, $true)
        try {
            $text = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    $text | ConvertFrom-Json
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $temporaryPath = "$Path.$PID.tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}
