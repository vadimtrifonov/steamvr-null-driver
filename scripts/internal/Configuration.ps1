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

function Get-OpenVrEnvironment {
    param(
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    [pscustomobject][ordered]@{
        VR_CONFIG_PATH = ConvertTo-FullPath $PrivateConfigRoot
        VR_LOG_PATH = ConvertTo-FullPath $PrivateLogRoot
    }
}

function Initialize-PrivateHeadlessConfiguration {
    param(
        [Parameter(Mandatory)][string]$SourceConfigRoot,
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    $sourceSettingsPath = ConvertTo-FullPath (Join-Path $SourceConfigRoot 'steamvr.vrsettings')
    $privateSettingsPath = ConvertTo-FullPath (Join-Path $PrivateConfigRoot 'steamvr.vrsettings')
    $privateChaperonePath = ConvertTo-FullPath (Join-Path $PrivateConfigRoot 'chaperone_info.vrchap')
    $sourceAppConfigPath = ConvertTo-FullPath (Join-Path $SourceConfigRoot 'appconfig.json')
    $privateAppConfigPath = ConvertTo-FullPath (Join-Path $PrivateConfigRoot 'appconfig.json')

    $sourceSettings = [System.IO.File]::ReadAllText($sourceSettingsPath)
    $headlessSettings = ConvertTo-HeadlessSettingsText -InputText $sourceSettings

    New-Item -ItemType Directory -Path $PrivateConfigRoot, $PrivateLogRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($privateSettingsPath, $headlessSettings, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($privateChaperonePath, (Get-TemporaryChaperoneText), [System.Text.UTF8Encoding]::new($false))

    $appConfigCopied = Test-Path -LiteralPath $sourceAppConfigPath -PathType Leaf
    if ($appConfigCopied) {
        [System.IO.File]::WriteAllBytes($privateAppConfigPath, [System.IO.File]::ReadAllBytes($sourceAppConfigPath))
    }

    [pscustomobject]@{
        sourceSettingsPath = $sourceSettingsPath
        privateSettingsPath = $privateSettingsPath
        privateChaperonePath = $privateChaperonePath
        appConfigCopied = $appConfigCopied
    }
}
