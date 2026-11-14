# SPDX-License-Identifier: GPL-2.0-or-later
# WindowsiOS: one-time Windows setup for running in the engine on an iPad.
#
# Runs once as SYSTEM during Windows Setup (unattend specialize pass, see
# scripts/provision_windows_arm64.py). There is no graphics driver in the VM, so Windows draws
# everything with the CPU; the settings below cut that work and the background load:
#   - visual effects: animations, transparency, shadows and window-drag redraw off; ClearType kept
#   - preinstalled extras removed (news, Xbox, Clipchamp, Copilot, Outlook, Teams, widgets ...)
#   - background apps, Widgets, Copilot, Spotlight, tips and promoted apps off
#   - Edge: no first-run wizard, no startup boost, no running in the background
#   - SysMain and telemetry service off; OneDrive not auto-installed for the new account
#   - Windows Update asks before downloading (so it never starts a large download on its own);
#     Microsoft Defender stays on, limited to 20% CPU for scans
#   - a sign-in task that sets the right display scaling for the screen resolution
# Every step is independent: a failure is logged to C:\WinIOS\setup.log and setup carries on.
#
# -CurrentUser: for a Windows that is already set up (run by winios-tune-now.ps1 as administrator):
# the per-account settings and app removals also go to the signed-in account.

param([switch]$CurrentUser)

$ErrorActionPreference = 'Continue'
$Dir = 'C:\WinIOS'
$Log = Join-Path $Dir 'setup.log'
$Summary = New-Object System.Collections.Generic.List[string]
New-Item -ItemType Directory -Path $Dir -Force | Out-Null

function Log([string]$msg) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $msg
    Add-Content -Path $Log -Value $line
}

function Step([string]$name, [scriptblock]$body) {
    $t0 = Get-Date
    try {
        & $body
        Log ("OK   {0} ({1:N0} s)" -f $name, ((Get-Date) - $t0).TotalSeconds)
    } catch {
        Log ("FAIL {0}: {1}" -f $name, $_.Exception.Message)
        $Summary.Add("failed: $name")
    }
}

function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

Log "WindowsiOS setup starting ($([Environment]::OSVersion.VersionString))"

# ---------------------------------------------------------------- machine-wide policies
Step 'machine policies' {
    $P = 'HKLM:\SOFTWARE\Policies\Microsoft'
    Set-Reg "$P\Windows\AppPrivacy" 'LetAppsRunInBackground' 2          # no background apps
    Set-Reg "$P\Dsh" 'AllowNewsAndInterests' 0                            # Widgets off
    Set-Reg "$P\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-Reg "$P\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1  # no promoted apps
    Set-Reg "$P\Windows\CloudContent" 'DisableConsumerAccountStateContent' 1
    Set-Reg "$P\Windows\CloudContent" 'DisableSoftLanding' 1
    Set-Reg "$P\Windows\DataCollection" 'AllowTelemetry' 1                # Required (minimum on Pro)
    Set-Reg "$P\Windows\Windows Search" 'AllowCortana' 0
    Set-Reg "$P\Windows\Windows Search" 'DisableWebSearch' 1
    Set-Reg "$P\Windows\Windows Search" 'ConnectedSearchUseWeb' 0
    Set-Reg "$P\Windows\DeliveryOptimization" 'DODownloadMode' 0          # no peer-to-peer uploads
    Set-Reg "$P\Windows\WindowsUpdate\AU" 'NoAutoUpdate' 0
    Set-Reg "$P\Windows\WindowsUpdate\AU" 'AUOptions' 2                   # notify before downloading
    Set-Reg "$P\Windows\GameDVR" 'AllowGameDVR' 0
    Set-Reg "$P\Edge" 'HideFirstRunExperience' 1
    Set-Reg "$P\Edge" 'StartupBoostEnabled' 0
    Set-Reg "$P\Edge" 'BackgroundModeEnabled' 0
    Set-Reg "$P\Edge" 'ShowRecommendationsEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 0
    # After a sign-out (the display-scaling switch signs out once), sign straight back in.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'ForceAutoLogon' '1' 'String'
}

# ---------------------------------------------------------------- services
Step 'services' {
    foreach ($svc in 'SysMain', 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo') {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            Log "     service $svc disabled"
        }
    }
}

# ---------------------------------------------------------------- Microsoft Defender: on, gentler
Step 'defender cpu limits' {
    Set-MpPreference -ScanAvgCPULoadFactor 20 -EnableLowCpuPriority $true -ErrorAction Stop
}

# ---------------------------------------------------------------- hibernation off (VM)
Step 'hibernation off' { powercfg.exe /hibernate off | Out-Null }

# ---------------------------------------------------------------- preinstalled extras
$RemoveApps = @(
        'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
        'Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider', 'Microsoft.MicrosoftOfficeHub',
        'Microsoft.OutlookForWindows', 'MSTeams', 'MicrosoftTeams', 'Microsoft.GamingApp',
        'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.Xbox.TCUI', 'Microsoft.Edge.GameAssist', 'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.GetHelp', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.People',
        'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos', 'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice',
        'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.Windows.DevHome', 'MicrosoftWindows.Client.WebExperience',
        'Microsoft.549981C3F5F10', 'Microsoft.WindowsCommunicationsApps'
)
Step 'remove preinstalled extras' {
    $remove = $RemoveApps
    $removed = 0
    $packages = Get-AppxProvisionedPackage -Online
    foreach ($pkg in $packages) {
        if ($remove -contains $pkg.DisplayName) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                $removed++
                Log "     removed $($pkg.DisplayName)"
            } catch {
                Log "     could not remove $($pkg.DisplayName): $($_.Exception.Message)"
            }
        }
    }
    $Summary.Add("removed $removed preinstalled apps")
}

# ---------------------------------------------------------------- per-account settings
# $U: the account's registry root, e.g. Registry::HKEY_USERS\WinIOSDefault or Registry::HKEY_CURRENT_USER
function Set-AccountTuning([string]$U) {
    $CV = "$U\Software\Microsoft\Windows\CurrentVersion"
    # Visual effects: "best performance", then ClearType back on.
    Set-Reg "$CV\Explorer\VisualEffects" 'VisualFXSetting' 3
    Set-Reg "$U\Control Panel\Desktop" 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
    Set-Reg "$U\Control Panel\Desktop" 'FontSmoothing' '2' 'String'
    Set-Reg "$U\Control Panel\Desktop" 'FontSmoothingType' 2
    Set-Reg "$U\Control Panel\Desktop" 'DragFullWindows' '0' 'String'
    Set-Reg "$U\Control Panel\Desktop" 'MenuShowDelay' '0' 'String'
    Set-Reg "$U\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '0' 'String'
    Set-Reg "$CV\Themes\Personalize" 'EnableTransparency' 0
    Set-Reg "$U\Software\Microsoft\Windows\DWM" 'EnableAeroPeek' 0
    Set-Reg "$CV\Explorer\Advanced" 'TaskbarAnimations' 0
    Set-Reg "$CV\Explorer\Advanced" 'ListviewAlphaSelect' 0
    Set-Reg "$CV\Explorer\Advanced" 'ListviewShadow' 0
    # Taskbar and Start: no Widgets, Copilot or Task View buttons, search as an icon.
    Set-Reg "$CV\Explorer\Advanced" 'TaskbarDa' 0
    Set-Reg "$CV\Explorer\Advanced" 'ShowCopilotButton' 0
    Set-Reg "$CV\Explorer\Advanced" 'ShowTaskViewButton' 0
    Set-Reg "$CV\Explorer\Advanced" 'Start_IrisRecommendations' 0
    Set-Reg "$CV\Search" 'SearchboxTaskbarMode' 1
    Set-Reg "$CV\Search" 'BingSearchEnabled' 0
    # Tips, suggestions, promoted and silently installed apps, Spotlight.
    $CDM = "$CV\ContentDeliveryManager"
    foreach ($v in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
                   'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
                   'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'RotatingLockScreenEnabled',
                   'RotatingLockScreenOverlayEnabled', 'SubscribedContent-310093Enabled',
                   'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
                   'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
                   'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
                   'SubscribedContent-353698Enabled') {
        Set-Reg $CDM $v 0
    }
    Set-Reg "$CV\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
    Set-Reg "$U\Software\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsSpotlightFeatures' 1
    Set-Reg "$U\Software\Policies\Microsoft\Windows\CloudContent" 'DisableSpotlightCollectionOnDesktop' 1
    Set-Reg "$U\Software\Policies\Microsoft\Windows\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-Reg "$U\System\GameConfigStore" 'GameDVR_Enabled' 0
    Set-Reg "$CV\GameDVR" 'AppCaptureEnabled' 0
    # Background apps (older per-user switch, alongside the machine policy above).
    Set-Reg "$CV\BackgroundAccessApplications" 'GlobalUserDisabled' 1
    # OneDrive: not installed and started automatically at the first sign-in.
    Remove-ItemProperty -LiteralPath "$CV\Run" -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
}

# The account is created after this pass, from the default profile, so the settings go there.
Step 'default user settings' {
    $hive = 'HKU\WinIOSDefault'
    reg.exe load $hive 'C:\Users\Default\NTUSER.DAT' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'cannot load the default user hive' }
    try {
        Set-AccountTuning 'Registry::HKEY_USERS\WinIOSDefault'
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 1
        reg.exe unload $hive | Out-Null
    }
}

if ($CurrentUser) {
    Step 'settings for the signed-in account' {
        Set-AccountTuning 'Registry::HKEY_CURRENT_USER'
        Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
    }
    Step 'remove extras from the signed-in account' {
        $n = 0
        foreach ($name in $RemoveApps) {
            foreach ($pkg in (Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)) {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop; $n++; Log "     removed $name for this account" }
                catch { Log "     could not remove $name for this account: $($_.Exception.Message)" }
            }
        }
        $Summary.Add("removed $n apps from this account")
    }
}

# ---------------------------------------------------------------- display scaling at every sign-in
Step 'display scaling task' {
    $cmd = 'conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\WinIOS\winios-display.ps1"'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'WinIOSDisplay' $cmd 'String'
}

$Summary.Insert(0, "WindowsiOS setup finished $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
Set-Content -Path (Join-Path $Dir 'setup-summary.txt') -Value $Summary
Log 'done'
exit 0
