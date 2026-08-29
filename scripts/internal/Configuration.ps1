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

function Initialize-PrivateHeadlessConfiguration {
    param(
        [Parameter(Mandatory)][string]$SourceConfigRoot,
        [Parameter(Mandatory)][string]$ConfigRoot,
        [Parameter(Mandatory)][string]$LogRoot
    )

    $sourceSettingsPath = ConvertTo-FullPath (Join-Path $SourceConfigRoot 'steamvr.vrsettings')
    $settingsPath = ConvertTo-FullPath (Join-Path $ConfigRoot 'steamvr.vrsettings')
    $chaperonePath = ConvertTo-FullPath (Join-Path $ConfigRoot 'chaperone_info.vrchap')
    $sourceAppConfigPath = ConvertTo-FullPath (Join-Path $SourceConfigRoot 'appconfig.json')
    $appConfigPath = ConvertTo-FullPath (Join-Path $ConfigRoot 'appconfig.json')

    $sourceSettings = [System.IO.File]::ReadAllText($sourceSettingsPath)
    $headlessSettings = ConvertTo-HeadlessSettingsText -InputText $sourceSettings

    New-Item -ItemType Directory -Path $ConfigRoot, $LogRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($settingsPath, $headlessSettings, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($chaperonePath, (Get-TemporaryChaperoneText), [System.Text.UTF8Encoding]::new($false))

    $appConfigCopied = Test-Path -LiteralPath $sourceAppConfigPath -PathType Leaf
    if ($appConfigCopied) {
        [System.IO.File]::WriteAllBytes($appConfigPath, [System.IO.File]::ReadAllBytes($sourceAppConfigPath))
    }

    [pscustomobject]@{
        sourceSettingsPath = $sourceSettingsPath
        settingsPath = $settingsPath
        chaperonePath = $chaperonePath
        appConfigCopied = $appConfigCopied
    }
}
