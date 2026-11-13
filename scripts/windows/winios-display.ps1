# SPDX-License-Identifier: GPL-2.0-or-later
# WindowsiOS: display scaling that follows the screen resolution the iPad app chose.
#
# Runs at every sign-in (HKLM Run key, set by winios-setup.ps1). Only when Windows comes up at a
# screen width it has not seen last time does it change anything: 200% scaling for the iPad's
# full ("Sharp") resolution, 100% for half ("Smooth") resolution. Scaling changes need a new
# sign-in, so it then signs out once; automatic sign-in brings the desktop straight back.
# Scaling you pick yourself in Settings is left alone until the resolution changes again.

$ErrorActionPreference = 'SilentlyContinue'
$vc = Get-CimInstance -ClassName Win32_VideoController |
      Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
$width = [int]$vc.CurrentHorizontalResolution
if ($width -le 0) { exit 0 }

$state = 'HKCU:\Software\WinIOS'
if (-not (Test-Path $state)) { New-Item -Path $state -Force | Out-Null }
$last = (Get-ItemProperty -Path $state -Name ScreenWidth).ScreenWidth
if ($last -eq $width) { exit 0 }
New-ItemProperty -Path $state -Name ScreenWidth -Value $width -PropertyType DWord -Force | Out-Null

$desk = 'HKCU:\Control Panel\Desktop'
$current = (Get-ItemProperty -Path $desk -Name LogPixels).LogPixels
if (-not $current) { $current = 96 }
$wanted = if ($width -ge 1800) { 192 } else { 96 }
if ($current -eq $wanted) { exit 0 }

if ($wanted -eq 96) {
    Remove-ItemProperty -Path $desk -Name LogPixels
    New-ItemProperty -Path $desk -Name Win8DpiScaling -Value 0 -PropertyType DWord -Force | Out-Null
} else {
    New-ItemProperty -Path $desk -Name LogPixels -Value $wanted -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $desk -Name Win8DpiScaling -Value 1 -PropertyType DWord -Force | Out-Null
}
Start-Sleep -Seconds 2
shutdown.exe /l
