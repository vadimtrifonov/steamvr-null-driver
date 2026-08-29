function Get-NullDriverSettingsText {
    @'
{
  "steamvr": {
    "requireHmd": false,
    "forcedDriver": "null",
    "activateMultipleDrivers": false,
    "startDashboardFromAppLaunch": false,
    "startOverlayAppsFromDashboard": false,
    "enableHomeApp": false
  },
  "driver_null": {
    "enable": true
  },
  "dashboard": {
    "enableDashboard": false
  },
  "direct_mode": {
    "enable": false
  }
}
'@
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
      "time": "temporary null-driver session",
      "universeID": 2
    }
  ],
  "version": 5
}
'@
}

function Get-OpenVrEnvironment {
    param(
        [Parameter(Mandatory)][string]$SteamVRRoot,
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    [pscustomobject][ordered]@{
        VR_OVERRIDE = ConvertTo-FullPath $SteamVRRoot
        VR_CONFIG_PATH = ConvertTo-FullPath $PrivateConfigRoot
        VR_LOG_PATH = ConvertTo-FullPath $PrivateLogRoot
    }
}

function Initialize-PrivateNullDriverConfiguration {
    param(
        [Parameter(Mandatory)][string]$PrivateConfigRoot,
        [Parameter(Mandatory)][string]$PrivateLogRoot
    )

    $privateSettingsPath = ConvertTo-FullPath (Join-Path $PrivateConfigRoot 'steamvr.vrsettings')
    $privateChaperonePath = ConvertTo-FullPath (Join-Path $PrivateConfigRoot 'chaperone_info.vrchap')

    New-Item -ItemType Directory -Path $PrivateConfigRoot, $PrivateLogRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($privateSettingsPath, (Get-NullDriverSettingsText), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($privateChaperonePath, (Get-TemporaryChaperoneText), [System.Text.UTF8Encoding]::new($false))
}
