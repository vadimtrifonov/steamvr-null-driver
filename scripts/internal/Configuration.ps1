$script:ProtectedConfigPaths = @(
    'steamvr.vrsettings',
    'chaperone_info.vrchap',
    'chaperone_info.vrchap.tmp',
    'vrappconfig\openvr.tool.steamvr_room_setup.vrappconfig',
    'steamvr.vrstats'
)

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    } else {
        $Object.$Name = $Value
    }
}

function ConvertTo-HeadlessSettingsText {
    param([Parameter(Mandatory)][string]$InputText)

    $settings = $InputText | ConvertFrom-Json
    foreach ($sectionName in @('steamvr', 'driver_null', 'dashboard')) {
        if ($null -eq $settings.PSObject.Properties[$sectionName]) {
            $settings | Add-Member -MemberType NoteProperty -Name $sectionName -Value ([pscustomobject]@{})
        }
    }

    Set-ObjectProperty -Object $settings.steamvr -Name 'requireHmd' -Value $false
    Set-ObjectProperty -Object $settings.steamvr -Name 'forcedDriver' -Value 'null'
    Set-ObjectProperty -Object $settings.steamvr -Name 'activateMultipleDrivers' -Value $false
    Set-ObjectProperty -Object $settings.steamvr -Name 'startDashboardFromAppLaunch' -Value $false
    Set-ObjectProperty -Object $settings.steamvr -Name 'startOverlayAppsFromDashboard' -Value $false
    Set-ObjectProperty -Object $settings.steamvr -Name 'enableHomeApp' -Value $false
    Set-ObjectProperty -Object $settings.driver_null -Name 'enable' -Value $true
    Set-ObjectProperty -Object $settings.dashboard -Name 'enableDashboard' -Value $false

    ($settings | ConvertTo-Json -Depth 100) + [Environment]::NewLine
}

function Get-TemporaryChaperoneText {
    @'
{
  "jsonid": "chaperone_info",
  "universes": [
    {
      "collision_bounds": [],
      "play_area": [ 1.0, 1.0 ],
      "seated": { "translation": [ 0.0, 0.0, 0.0 ], "yaw": 0.0 },
      "standing": { "translation": [ 0.0, 0.0, 0.0 ], "yaw": 0.0 },
      "time": "temporary headless session",
      "universeID": 2
    }
  ],
  "version": 5
}
'@
}

function Get-ProtectedConfigPaths {
    param([Parameter(Mandatory)][string]$ConfigRoot)

    @($script:ProtectedConfigPaths | ForEach-Object { ConvertTo-FullPath (Join-Path $ConfigRoot $_) })
}

function New-ProtectedFileManifest {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $entries = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $Paths.Count; $index++) {
        $path = ConvertTo-FullPath $Paths[$index]
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $entry = [ordered]@{
            path = $path
            existed = $exists
            backup = $null
            sha256 = $null
        }

        if ($exists) {
            $backupPath = Join-Path $BackupDirectory "$index.bin"
            $bytes = [System.IO.File]::ReadAllBytes($path)
            [System.IO.File]::WriteAllBytes($backupPath, $bytes)
            $entry.backup = ConvertTo-FullPath $backupPath
            $entry.sha256 = Get-ByteHash -Bytes $bytes
            if ((Get-ByteHash -Bytes ([System.IO.File]::ReadAllBytes($backupPath))) -ne $entry.sha256) {
                throw "The backup could not be verified for '$path'."
            }
        }

        $entries.Add([pscustomobject]$entry)
    }

    Write-JsonAtomic -Path $ManifestPath -Value @($entries)
    @($entries)
}

function Restore-ProtectedFileManifest {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string[]]$ExpectedPaths
    )

    $entries = @(Read-JsonShared -Path $ManifestPath)
    $expected = @($ExpectedPaths | ForEach-Object { ConvertTo-FullPath $_ } | Sort-Object)
    $recorded = @($entries | ForEach-Object { ConvertTo-FullPath ([string]$_.path) } | Sort-Object)
    if ($expected.Count -ne $recorded.Count -or (Compare-Object -ReferenceObject $expected -DifferenceObject $recorded)) {
        throw 'The protected-file manifest does not match the declared protected paths.'
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $allRestored = $true

    foreach ($entry in $entries) {
        $restored = $false
        $errorText = $null
        try {
            if ([bool]$entry.existed) {
                if (-not $entry.backup -or -not $entry.sha256) {
                    throw 'An existing protected file has no complete backup record.'
                }
                $backupBytes = [System.IO.File]::ReadAllBytes([string]$entry.backup)
                if ((Get-ByteHash -Bytes $backupBytes) -ne [string]$entry.sha256) {
                    throw 'The protected-file backup hash does not match its manifest.'
                }
                $parent = Split-Path -Parent ([string]$entry.path)
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                [System.IO.File]::WriteAllBytes([string]$entry.path, $backupBytes)
                $restored = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$entry.path)).Hash -eq [string]$entry.sha256
            } else {
                if (Test-Path -LiteralPath ([string]$entry.path)) {
                    Remove-Item -LiteralPath ([string]$entry.path) -Force
                }
                $restored = -not (Test-Path -LiteralPath ([string]$entry.path))
            }
        } catch {
            $errorText = $_.Exception.Message
        }

        if (-not $restored) {
            $allRestored = $false
        }
        $results.Add([pscustomobject]@{
            path = [string]$entry.path
            restored = $restored
            error = $errorText
        })
    }

    [pscustomobject]@{
        restored = $allRestored
        files = @($results)
    }
}
