[CmdletBinding()]
param([Parameter(Mandatory)]$Context)

$module = $Context.Module

$settingsText = & $module { Get-HeadlessSettingsText }
$settings = $settingsText | ConvertFrom-Json
Assert-PropertySet `
    -Value $settings `
    -Names @('steamvr', 'driver_null', 'dashboard', 'direct_mode') `
    -Message 'The headless settings have an unexpected top-level shape.'
Assert-PropertySet `
    -Value $settings.steamvr `
    -Names @(
        'requireHmd',
        'forcedDriver',
        'activateMultipleDrivers',
        'startDashboardFromAppLaunch',
        'startOverlayAppsFromDashboard',
        'enableHomeApp'
    ) `
    -Message 'The steamvr section has an unexpected shape.'
Assert-Equal $settings.steamvr.requireHmd $false 'The headless settings require an HMD.'
Assert-Equal $settings.steamvr.forcedDriver 'null' 'The headless settings do not force the null driver.'
Assert-Equal $settings.steamvr.activateMultipleDrivers $false 'The headless settings allow multiple drivers.'
Assert-Equal $settings.steamvr.startDashboardFromAppLaunch $false 'The headless settings start the dashboard.'
Assert-Equal $settings.steamvr.startOverlayAppsFromDashboard $false 'The headless settings start dashboard overlays.'
Assert-Equal $settings.steamvr.enableHomeApp $false 'The headless settings enable SteamVR Home.'
Assert-Equal $settings.driver_null.enable $true 'The headless settings do not enable the null driver.'
Assert-Equal $settings.dashboard.enableDashboard $false 'The headless settings enable the dashboard.'
Assert-Equal $settings.direct_mode.enable $false 'The headless settings enable Direct Display Mode.'
Complete-Test 'headless settings define null-only mode'

$chaperone = (& $module { Get-TemporaryChaperoneText }) | ConvertFrom-Json
Assert-Equal $chaperone.jsonid 'chaperone_info' 'The temporary chaperone identifier is invalid.'
Assert-Equal $chaperone.version 5 'The temporary chaperone version is invalid.'
Assert-Equal $chaperone.universes.Count 1 'The temporary chaperone contains more than one universe.'
Assert-Equal $chaperone.universes[0].universeID 2 'The temporary chaperone does not use the null-driver universe.'
Assert-True ($chaperone.universes[0].universeID -isnot [string]) 'The temporary universe ID is a string.'
Assert-True ($null -ne $chaperone.universes[0].seated) 'The temporary chaperone has no seated origin.'
Assert-True ($null -ne $chaperone.universes[0].standing) 'The temporary chaperone has no standing origin.'
Assert-Equal $chaperone.universes[0].collision_bounds.Count 0 'The temporary chaperone defines collision bounds.'
Complete-Test 'temporary chaperone defines null-driver origins'

$nullOnlyLog = @'
Loaded server driver null (IServerTrackedDeviceProvider_004) from C:\SteamVR\driver_null.dll
Driver 'null' started activation of tracked device with serial number 'Null Serial Number'
Active HMD set to null.Null Serial Number
'@
$assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $nullOnlyLog
Assert-True $assessment.ready 'Null-only startup evidence was not accepted.'
Assert-True $assessment.nullDriverLoaded 'The null driver was not reported as loaded.'
Assert-Equal $assessment.unexpectedDrivers.Count 0 'The null driver was classified as unexpected.'
Assert-Equal $assessment.unexpectedHmdDrivers.Count 0 'The null HMD was classified as unexpected.'
Complete-Test 'null-only startup evidence is accepted'

$nonNullDriverLog = @'
Loaded server driver null (IServerTrackedDeviceProvider_004) from C:\SteamVR\driver_null.dll
Active HMD set to null.Null Serial Number
Loaded server driver tracked_headset (IServerTrackedDeviceProvider_004) from C:\Driver\tracked_headset.dll
Active HMD set to tracked_headset.Serial 1
'@
$assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $nonNullDriverLog
Assert-True $assessment.modeViolation 'Non-null driver evidence did not cause a mode violation.'
Assert-True ($assessment.unexpectedDrivers -contains 'tracked_headset') 'The non-null driver was not reported.'
Assert-True ($assessment.unexpectedHmdDrivers -contains 'tracked_headset') 'The non-null HMD was not reported.'
Assert-True (-not $assessment.ready) 'Non-null driver evidence was accepted as ready.'
Complete-Test 'non-null driver evidence is rejected'

$roomSetupLog = $nullOnlyLog + "`nStarting process C:\SteamVR\tools\steamvr_room_setup.exe as app openvr.tool.steamvr_room_setup"
$assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $roomSetupLog
Assert-True $assessment.roomSetupDetected 'Room Setup evidence was not detected.'
Assert-True (-not $assessment.ready) 'Room Setup evidence was accepted as ready.'
Complete-Test 'Room Setup evidence is rejected'

$directModeLog = $nullOnlyLog + "`n[Display] Enabling direct mode for NVIDIA [Vid=0x0000 Pid=0x0000]..."
$assessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $directModeLog
Assert-True $assessment.directModeDetected 'Direct Display Mode evidence was not detected.'
Assert-True $assessment.modeViolation 'Direct Display Mode evidence did not cause a mode violation.'
Assert-True (-not $assessment.ready) 'Direct Display Mode evidence was accepted as ready.'
Complete-Test 'Direct Display Mode evidence is rejected'

$sharedLogPath = Join-Path $Context.Root 'shared-vrserver.txt'
$missingLogText = & $module { param($Path) Read-VrLogText -Path $Path } $sharedLogPath
Assert-Equal $missingLogText '' 'A missing SteamVR log did not read as empty.'
[System.IO.File]::WriteAllText($sharedLogPath, $nullOnlyLog)
$sharedLogText = & $module { param($Path) Read-VrLogText -Path $Path } $sharedLogPath
$sharedAssessment = & $module { param($Text) Get-VrLogAssessment -Text $Text } $sharedLogText
Assert-True $sharedAssessment.ready 'The shared log reader did not return complete startup evidence.'
Complete-Test 'SteamVR log can be read while shared'

$privateRunRoot = Join-Path $Context.Root 'private-headless-mode'
$privateConfigRoot = Join-Path $privateRunRoot 'config'
$privateLogRoot = Join-Path $privateRunRoot 'logs'
& $module {
    param($ConfigRoot, $LogRoot)
    Initialize-PrivateHeadlessConfiguration -PrivateConfigRoot $ConfigRoot -PrivateLogRoot $LogRoot
} $privateConfigRoot $privateLogRoot
$privateSettings = Get-Content -LiteralPath (Join-Path $privateConfigRoot 'steamvr.vrsettings') -Raw | ConvertFrom-Json
$privateChaperone = Get-Content -LiteralPath (Join-Path $privateConfigRoot 'chaperone_info.vrchap') -Raw | ConvertFrom-Json
Assert-Equal $privateSettings.steamvr.forcedDriver 'null' 'The private settings do not force the null driver.'
Assert-Equal $privateSettings.direct_mode.enable $false 'The private settings enable Direct Display Mode.'
Assert-Equal $privateChaperone.universes[0].universeID 2 'The private chaperone uses the wrong universe.'
Assert-True (Test-Path -LiteralPath $privateLogRoot -PathType Container) 'The private log directory was not created.'
Assert-PropertySet `
    -Value $privateSettings `
    -Names @('steamvr', 'driver_null', 'dashboard', 'direct_mode') `
    -Message 'The private settings have an unexpected top-level shape.'
Complete-Test 'private run configuration contains required files'

$processInfo = & $module {
    param($Path, $RuntimeRoot, $ConfigRoot, $LogRoot)
    New-OpenVrProcessInfo `
        -Path $Path `
        -SteamVrRoot $RuntimeRoot `
        -PrivateConfigRoot $ConfigRoot `
        -PrivateLogRoot $LogRoot
} (Join-Path $Context.SteamVrRoot 'bin\win64\vrstartup.exe') $Context.SteamVrRoot $privateConfigRoot $privateLogRoot
Assert-Equal $processInfo.Environment['VR_OVERRIDE'] ([IO.Path]::GetFullPath($Context.SteamVrRoot)) 'VR_OVERRIDE does not select the fixture runtime.'
Assert-Equal $processInfo.Environment['VR_CONFIG_PATH'] ([IO.Path]::GetFullPath($privateConfigRoot)) 'VR_CONFIG_PATH does not select the private configuration.'
Assert-Equal $processInfo.Environment['VR_LOG_PATH'] ([IO.Path]::GetFullPath($privateLogRoot)) 'VR_LOG_PATH does not select the private logs.'
Complete-Test 'OpenVR child environment uses private run paths'
