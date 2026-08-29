$global:SteamVRNullDriverPassedTests = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-PropertySet {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Message
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join ',') -ne ($expected -join ',')) {
        throw "$Message Expected '$($expected -join ', ')', got '$($actual -join ', ')'."
    }
}

function Complete-Test {
    param([Parameter(Mandatory)][string]$Name)

    $global:SteamVRNullDriverPassedTests.Add($Name)
}

function New-FixtureRunConfiguration {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$SteamVRRoot,
        [DateTime]$CreatedUtc = [DateTime]::UtcNow,
        [DateTime]$DeadlineUtc = [DateTime]::UtcNow.AddMinutes(10)
    )

    [pscustomobject][ordered]@{
        schemaVersion = 6
        runId = $RunId
        createdUtc = $CreatedUtc.ToString('o')
        deadlineUtc = $DeadlineUtc.ToString('o')
        steamVRRoot = $SteamVRRoot
    }
}

function Write-FixtureRunConfiguration {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Configuration
    )

    $Configuration |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Encoding utf8NoBOM
    & $Module { param($Run) Read-RunConfiguration -RunDirectory $Run } $RunDirectory
}

function New-FixtureSteamVRRuntime {
    param([Parameter(Mandatory)][string]$Root)

    foreach ($relativePath in @(
        'bin\win64\vrstartup.exe',
        'bin\win64\vrserver.exe',
        'bin\win64\vrcompositor.exe',
        'bin\win64\vrmonitor.exe',
        'drivers\null\bin\win64\driver_null.dll'
    )) {
        $path = Join-Path $Root $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, '')
    }
}

function New-FixtureSteamClientRecord {
    [pscustomobject]@{
        pid = 1
        name = 'steam'
        path = 'C:\FixtureSteam\steam.exe'
        creationUtc = '2026-01-01T00:00:00Z'
    }
}
