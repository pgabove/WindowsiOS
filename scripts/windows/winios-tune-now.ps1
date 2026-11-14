# SPDX-License-Identifier: GPL-2.0-or-later
# WindowsiOS: apply the speed tuning to a Windows that is already set up (images built before the
# tuning became part of Windows setup). In Windows, open Terminal (Admin) and run:
#
#   irm https://raw.githubusercontent.com/pgabove/WindowsiOS/ipad-26h2/scripts/windows/winios-tune-now.ps1 | iex
#
# It downloads winios-setup.ps1 and winios-display.ps1 to C:\WinIOS, runs the setup for this PC and
# the signed-in account (see winios-setup.ps1 for every change), then asks for a restart.
& {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'Run this in Terminal (Admin): right-click Start > Terminal (Admin).' -ForegroundColor Yellow
        return
    }
    $base = 'https://raw.githubusercontent.com/pgabove/WindowsiOS/ipad-26h2/scripts/windows'
    $dir = 'C:\WinIOS'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($f in 'winios-setup.ps1', 'winios-display.ps1') {
        Write-Host "Downloading $f ..."
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$f" -OutFile (Join-Path $dir $f)
    }
    Write-Host 'Tuning Windows (a few minutes) ...'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'winios-setup.ps1') -CurrentUser
    Write-Host ''
    Get-Content (Join-Path $dir 'setup-summary.txt')
    Write-Host ''
    Write-Host 'Done. Restart Windows to finish: Start > Power > Restart.' -ForegroundColor Green
}
