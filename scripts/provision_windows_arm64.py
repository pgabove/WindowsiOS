#!/opt/homebrew/bin/python3
"""
Provision a ready-to-boot Windows 11 Pro ARM64 (24H2, Build 26100) GPT NVMe disk image
and UEFI NVRAM vars file from the official Microsoft ARM64 retail ESD using our native
ARM64 JIT (`build/winvm`), WinPE DISM (from an unsplit ExFAT `install.wim`), and BCDBOOT.

All intermediate and output files stay strictly inside work/.
"""

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"
WINVM = ROOT / "build" / "winvm"
ESD = WORK / "downloads" / "Win11_24H2_ARM64_en-us.esd"
INST_IMG = WORK / "installer_v4.img"
WIN_IMG = WORK / "windows11.img"
CODE_FD = WORK / "code.fd"
VARS_FD = WORK / "vars.fd"

# ---------------------------------------------------------------------------------------------
# iPad / 26H2 additions. With none of these set, the script behaves exactly as before (24H2 ESD).
#
#   WINIOS_ISO=/path/to/Win11_26H2_English_Arm64.iso
#       Use an official Microsoft Arm64 ISO instead of the retail ESD. Also picked automatically
#       when work/downloads/ holds exactly one *.iso and the 24H2 ESD is absent.
#   WINIOS_EDITION="Windows 11 Pro"     Edition name inside the ISO's install.wim.
#   WINIOS_USER / WINIOS_COMPUTER       Local account and PC name written into unattend.xml.
#   WINIOS_INSTALLER_MB                 Installer image size override, in MB.
#   work/drivers/NetKVM/                virtio-win NetKVM (w11/ARM64) files; injected when present.
#   --installer-only                    Build the installer image and firmware files, then stop.
#                                       Nothing runs build/winvm; Windows is installed on the iPad
#                                       itself from work/ipad_stage/ (needs the patched iOS app).
#   WINIOS_ESD=/path/to/file.esd        Retail ESD under any file name (scripts/ci_fetch_win11_esd.py).
#   WINIOS_ESD_IMAGE="Windows 11 Pro"   Image (index or name) to install from the ESD. Default 6.
#   WINIOS_DISK_GB=64                   Size of the Windows system disk in GB. Default 32.
# ---------------------------------------------------------------------------------------------
if os.environ.get("WINIOS_ESD"):
    ESD = Path(os.environ["WINIOS_ESD"]).expanduser()
_DOWNLOADS = WORK / "downloads"
_ISOS = sorted(_DOWNLOADS.glob("*.iso")) if _DOWNLOADS.is_dir() else []
if os.environ.get("WINIOS_ISO"):
    ISO = Path(os.environ["WINIOS_ISO"]).expanduser()
elif len(_ISOS) == 1 and not ESD.exists():
    ISO = _ISOS[0]
else:
    ISO = None
EDITION = os.environ.get("WINIOS_EDITION", "Windows 11 Pro")
WIN_USER = os.environ.get("WINIOS_USER", "Ammaar")
WIN_COMPUTER = os.environ.get("WINIOS_COMPUTER", "IPHONE-DUO")
NETKVM_DIR = WORK / "drivers" / "NetKVM"
# iPad addition: scripts that tune Windows for the engine (run during setup, see unattend below).
WINIOS_SCRIPTS_DIR = ROOT / "scripts" / "windows"
ISO_MNT = WORK / "_iso_mnt"
IPAD_STAGE = WORK / "ipad_stage"
WIMLIB = shutil.which("wimlib-imagex") or "/opt/homebrew/bin/wimlib-imagex"
DISK_GB = int(os.environ.get("WINIOS_DISK_GB", "32"))


def mount_iso():
    """Mount the ISO read-only at work/_iso_mnt (no-op when the ESD is used)."""
    if ISO is None:
        return
    subprocess.run(["hdiutil", "detach", str(ISO_MNT)], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ISO_MNT.mkdir(parents=True, exist_ok=True)
    run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", ISO_MNT, ISO])


def unmount_iso():
    if ISO is None:
        return
    subprocess.run(["hdiutil", "detach", str(ISO_MNT)], check=False)


def iso_path(*parts):
    """Case-insensitive lookup below the mounted ISO; None when a component is missing."""
    p = ISO_MNT
    for part in parts:
        hits = [c for c in p.iterdir() if c.name.lower() == part.lower()] if p.is_dir() else []
        if not hits:
            return None
        p = hits[0]
    return p


def winpe_source():
    """(wim, image) holding plain WinPE: ESD image 2, or image 1 of the ISO's sources/boot.wim."""
    if ISO is None:
        return ESD, "2"
    src = iso_path("sources", "boot.wim")
    if src is None:
        sys.exit(f"{ISO} has no sources/boot.wim")
    return src, "1"


def install_source():
    """(wim, image) holding the edition to install: ESD image 6, or EDITION by name from the ISO."""
    if ISO is None:
        return ESD, os.environ.get("WINIOS_ESD_IMAGE", "6")
    src = iso_path("sources", "install.wim") or iso_path("sources", "install.esd")
    if src is None:
        sys.exit(f"{ISO} has no sources/install.wim or sources/install.esd")
    return src, EDITION


def installer_size_mb():
    """Original 6400 MB for the ESD; for an ISO, large enough for its whole install image."""
    if os.environ.get("WINIOS_INSTALLER_MB"):
        return int(os.environ["WINIOS_INSTALLER_MB"])
    if ISO is None:
        return 6400
    src, _ = install_source()
    mb = src.stat().st_size >> 20
    if src.suffix.lower() == ".esd":
        mb = mb * 3 // 2  # exported as LZX, which is larger than the ESD's LZMS
    return max(6400, mb + 1500)


def netkvm_present():
    return NETKVM_DIR.is_dir() and any(p.suffix.lower() == ".inf" for p in NETKVM_DIR.iterdir())


def qemu_firmware(name):
    """EDK2 firmware shipped by Homebrew's qemu (Apple Silicon or Intel prefix)."""
    for prefix in ("/opt/homebrew", "/usr/local"):
        p = Path(prefix) / "share" / "qemu" / name
        if p.exists():
            return p
    sys.exit(f"Missing {name}: run `brew install qemu`")


def stage_for_ipad():
    """Collect the three files the iPad needs in work/ipad_stage/ (the big image as a hard link)."""
    IPAD_STAGE.mkdir(parents=True, exist_ok=True)
    for src, name in ((CODE_FD, "code.fd"), (VARS_FD, "vars.fd")):
        shutil.copyfile(src, IPAD_STAGE / name)
    dst = IPAD_STAGE / "installer.img"
    dst.unlink(missing_ok=True)
    try:
        os.link(INST_IMG, dst)
    except OSError:
        shutil.copyfile(INST_IMG, dst)
    print(f"\nSUCCESS: installer media staged in {IPAD_STAGE}", flush=True)
    for name in ("code.fd", "vars.fd", "installer.img"):
        print(f"  {name:14s} {(IPAD_STAGE / name).stat().st_size / (1 << 20):10.1f} MB", flush=True)
    print("Copy these three files to the iPad: Files > On My iPad > Windows 11 > Machines > Win11",
          flush=True)


STARTNET_CMD = r"""@echo off
wpeinit
echo [WIN11-PROVISION] WinPE booted on winvm ARM64 JIT! Locating 32 GB target NVMe disk...
echo list disk > X:\list.txt
diskpart /s X:\list.txt > X:\disks.log
type X:\disks.log

set TARGET_DISK=
for /f "tokens=1,2,3,4,5" %%a in (X:\disks.log) do (
  if /i "%%a"=="Disk" if /i "%%d %%e"=="32 GB" set TARGET_DISK=%%b
)
if "%TARGET_DISK%"=="" set TARGET_DISK=0
echo [WIN11-PROVISION] Partitioning Disk %TARGET_DISK% as GPT (EFI + MSR + NTFS)...
(
  echo select disk %TARGET_DISK%
  echo clean
  echo convert gpt
  echo create partition efi size=100
  echo format quick fs=fat32 label="System"
  echo assign letter=S
  echo create partition msr size=16
  echo create partition primary
  echo format quick fs=ntfs label="Windows"
  echo assign letter=W
) > X:\part.txt
diskpart /s X:\part.txt

set INST_WIM=
for %%l in (C D E F G H I J K L) do (
  if exist %%l:\sources\install.wim set INST_WIM=%%l:\sources\install.wim
)
if "%INST_WIM%"=="" (
  echo [WIN11-PROVISION] ERROR: Could not find unsplit sources\install.wim!
  ping -n 30 127.0.0.1 >nul
  exit /b 1
)

echo [WIN11-PROVISION] Applying unsplit Windows 11 Pro ARM64 image (%INST_WIM%) to W:\ ...
dism /Apply-Image /ImageFile:%INST_WIM% /Index:1 /ApplyDir:W:\
if errorlevel 1 (
  echo [WIN11-PROVISION] ERROR: DISM Apply-Image failed!
  find /i "Error" X:\windows\Logs\DISM\dism.log
  ping -n 60 127.0.0.1 >nul
  exit /b 1
)

if exist X:\Drivers\NetKVM\*.inf (
  echo [WIN11-PROVISION] Injecting virtio-win NetKVM Ethernet driver into the offline image...
  dism /Image:W:\ /Add-Driver /Driver:X:\Drivers\NetKVM /Recurse
  echo [WIN11-PROVISION] Copying NetKVM to W:\Drivers\NetKVM for pnputil during setup...
  xcopy X:\Drivers\NetKVM W:\Drivers\NetKVM\ /e /i /y /q
)

if exist X:\WinIOS\*.ps1 (
  echo [WIN11-PROVISION] Copying the WindowsiOS tuning scripts to W:\WinIOS...
  xcopy X:\WinIOS W:\WinIOS\ /e /i /y /q
)

echo [WIN11-PROVISION] Injecting unattend.xml and offline registry settings...
mkdir W:\Windows\Panther
copy /y X:\Windows\System32\unattend_panther.xml W:\Windows\Panther\unattend.xml

reg load HKLM\OFFSYS W:\Windows\System32\config\SYSTEM
reg add HKLM\OFFSYS\ControlSet001\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg unload HKLM\OFFSYS

reg load HKLM\OFFSOFT W:\Windows\System32\config\SOFTWARE
reg add HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f
reg unload HKLM\OFFSOFT

echo [WIN11-PROVISION] Installing UEFI Windows Boot Manager via bcdboot...
bcdboot W:\Windows /s S: /f UEFI
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} recoveryenabled no
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} bootmenupolicy standard

echo [WIN11-PROVISION] Phase 1 DISM + BCDBOOT complete! Shutting down cleanly...
wpeutil shutdown
"""

PANTHER_UNATTEND_XML = r"""<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>IPHONE-DUO</ComputerName>
      <TimeZone>Eastern Standard Time</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value></Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>Ammaar</Description>
            <DisplayName>Ammaar</DisplayName>
            <Group>Administrators</Group>
            <Name>Ammaar</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value></Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <Username>Ammaar</Username>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c "powercfg /h off &amp; powercfg /change monitor-timeout-ac 0 &amp; powercfg /change standby-timeout-ac 0"</CommandLine>
          <Description>Disable hibernation and display/sleep timeouts</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>cmd /c "bcdedit /set {default} bootmenupolicy standard &amp; bcdedit /set {default} recoveryenabled no"</CommandLine>
          <Description>Disable automatic recovery loops on hard VM stop</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>cmd /c "timeout /t 15 /nobreak &amp; shutdown /s /t 2 /f"</CommandLine>
          <Description>Clean shutdown once first desktop logon settles</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"""

# iPad / 26H2 addition: account and PC name come from WINIOS_USER / WINIOS_COMPUTER when set.
PANTHER_UNATTEND_XML = PANTHER_UNATTEND_XML.replace("Ammaar", WIN_USER).replace("IPHONE-DUO", WIN_COMPUTER)
# iPad / 26H2 addition: during setup (specialize pass, as SYSTEM) Windows adds the NetKVM driver that
# startnet.cmd copied to C:\Drivers\NetKVM. pnputil puts it in the driver store, so the network adapter
# gets it on the first boot with networking on. DISM /Add-Driver from this WinPE fails (0x80004002).
PANTHER_UNATTEND_XML = PANTHER_UNATTEND_XML.replace(
    "      </RunSynchronous>\n    </component>\n  </settings>\n\n  <settings pass=\"oobeSystem\">",
    "        <RunSynchronousCommand wcm:action=\"add\">\n"
    "          <Order>3</Order>\n"
    "          <Path>cmd /c \"pnputil /add-driver C:\\Drivers\\NetKVM\\*.inf /install &gt; C:\\Drivers\\pnputil.log 2&gt;&amp;1 &amp; exit /b 0\"</Path>\n"
    "        </RunSynchronousCommand>\n"
    "      </RunSynchronous>\n    </component>\n  </settings>\n\n  <settings pass=\"oobeSystem\">",
    1,
)
# iPad addition: tune Windows for the engine during setup (as SYSTEM): scripts/windows/winios-setup.ps1.
PANTHER_UNATTEND_XML = PANTHER_UNATTEND_XML.replace(
    "      </RunSynchronous>\n    </component>\n  </settings>\n\n  <settings pass=\"oobeSystem\">",
    "        <RunSynchronousCommand wcm:action=\"add\">\n"
    "          <Order>4</Order>\n"
    "          <Path>cmd /c \"if exist C:\\WinIOS\\winios-setup.ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\WinIOS\\winios-setup.ps1 &amp; exit /b 0\"</Path>\n"
    "        </RunSynchronousCommand>\n"
    "      </RunSynchronous>\n    </component>\n  </settings>\n\n  <settings pass=\"oobeSystem\">",
    1,
)
# iPad / 26H2 addition: startnet.cmd finds the system disk by its size, as diskpart prints it.
if DISK_GB != 32:
    STARTNET_CMD = STARTNET_CMD.replace("32 GB", f"{DISK_GB} GB")


def run(cmd, **kwargs):
    print(f"+ {' '.join(str(c) for c in cmd)}", flush=True)
    return subprocess.run([str(c) for c in cmd], check=True, **kwargs)


def make_custom_boot_wim(dest_boot_wim: Path):
    dest_boot_wim.parent.mkdir(parents=True, exist_ok=True)
    if dest_boot_wim.exists():
        dest_boot_wim.unlink()
    pe_src, pe_image = winpe_source()
    run([WIMLIB, "export", pe_src, pe_image, dest_boot_wim, "--compress=LZX", "--boot"])
    snet = WORK / "startnet.cmd"
    unat = WORK / "unattend_panther.xml"
    snet.write_text(STARTNET_CMD.replace("\n", "\r\n"), encoding="utf-8")
    unat.write_text(PANTHER_UNATTEND_XML.replace("\n", "\r\n"), encoding="utf-8")
    cmds = (
        f"add '{snet}' '/Windows/System32/startnet.cmd'\n"
        f"add '{unat}' '/Windows/System32/unattend_panther.xml'\n"
    ).encode("utf-8")
    if netkvm_present():
        print(f"Adding NetKVM driver files from {NETKVM_DIR} to WinPE (X:\\Drivers\\NetKVM)", flush=True)
        cmds += f"add '{NETKVM_DIR}' '/Drivers/NetKVM'\n".encode("utf-8")
    else:
        print(f"NOTE: no *.inf in {NETKVM_DIR}; Windows will have no Ethernet driver", flush=True)
    if WINIOS_SCRIPTS_DIR.is_dir():
        print(f"Adding Windows tuning scripts from {WINIOS_SCRIPTS_DIR} to WinPE (X:\\WinIOS)", flush=True)
        cmds += f"add '{WINIOS_SCRIPTS_DIR}' '/WinIOS'\n".encode("utf-8")
    run([WIMLIB, "update", dest_boot_wim, "1"], input=cmds)
    snet.unlink(missing_ok=True)
    unat.unlink(missing_ok=True)


def build_two_partition_installer():
    marker = WORK / ".installer_exfat_v4"
    if INST_IMG.exists() and marker.exists():
        print(f"[skip] {INST_IMG} already built ({INST_IMG.stat().st_size} bytes)", flush=True)
        return

    print("Building 2-partition GPT installer (FAT32 WinPE + ExFAT unsplit install.wim)...", flush=True)
    mount_iso()
    INST_IMG.unlink(missing_ok=True)
    with open(INST_IMG, "wb") as f:
        f.truncate(installer_size_mb() * 1024 * 1024)

    out = subprocess.check_output(["hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", str(INST_IMG)], text=True)
    whole_disk = out.strip().splitlines()[0].split()[0]
    print(f"Attached raw installer disk as {whole_disk}", flush=True)
    try:
        run([
            "diskutil", "partitionDisk", whole_disk, "GPT",
            "MS-DOS", "WINPE", "900M",
            "ExFAT", "WINWIM", "R",
        ])
        pe_root = Path("/Volumes/WINPE")
        wim_root = Path("/Volumes/WINWIM")
        if not pe_root.exists() or not wim_root.exists():
            raise RuntimeError(f"Expected /Volumes/WINPE and /Volumes/WINWIM after partitionDisk on {whole_disk}")

        # Extract small UEFI boot files (Index 1, skipping install.esd/boot.wim) into FAT32 WINPE
        stage_pe = WORK / "stage_pe_v4"
        shutil.rmtree(stage_pe, ignore_errors=True)
        stage_pe.mkdir(parents=True, exist_ok=True)
        if ISO is not None:
            # ISO media: the same boot files sit at the ISO root. Copy file data only, so the
            # read-only modes of the mounted ISO never land in the staging folder.
            if iso_path("efi") is None:
                raise RuntimeError(f"{ISO} has no efi/ folder; is it a Windows Arm64 ISO?")
            for name in ("efi", "boot", "bootmgr.efi"):
                src = iso_path(name)
                if src is None:
                    continue
                if src.is_dir():
                    for sub in sorted(src.rglob("*")):
                        rel = sub.relative_to(src)
                        if sub.is_dir():
                            (stage_pe / name / rel).mkdir(parents=True, exist_ok=True)
                        else:
                            (stage_pe / name / rel).parent.mkdir(parents=True, exist_ok=True)
                            shutil.copyfile(sub, stage_pe / name / rel)
                else:
                    shutil.copyfile(src, stage_pe / name)
        else:
            run([WIMLIB, "extract", ESD, "1", "/efi", "/boot", "/bootmgr.efi", f"--dest-dir={stage_pe}"])
        for item in stage_pe.iterdir():
            dest = pe_root / item.name
            if item.is_dir():
                shutil.copytree(item, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(item, dest)
        shutil.rmtree(stage_pe, ignore_errors=True)

        make_custom_boot_wim(pe_root / "sources" / "boot.wim")

        # Export unsplit Windows 11 Pro (Index 6) directly onto ExFAT WINWIM!
        (wim_root / "sources").mkdir(parents=True, exist_ok=True)
        inst_src, inst_image = install_source()
        run([WIMLIB, "export", inst_src, inst_image, wim_root / "sources" / "install.wim", "--compress=LZX"])
    finally:
        subprocess.run(["hdiutil", "detach", whole_disk], check=False)
        unmount_iso()

    marker.write_text("ok\n")
    # Clean old installer.dmg to save space inside work/
    old_dmg = WORK / "installer.dmg"
    if old_dmg.exists():
        old_dmg.unlink()


def run_winvm_phase(phase_name: str, extra_args: list[str], screen_png: Path, max_minutes: int):
    cmd_file = WORK / f"prov_{phase_name}.cmds"
    log_file = WORK / f"prov_{phase_name}.log"
    cmd_file.write_text("")
    cmd = [
        str(WINVM),
        "--headless",
        "--code", str(CODE_FD),
        "--vars", str(VARS_FD),
        "--disk", str(WIN_IMG),
        "--cpus", "4",
        "--ram", "4096",
        "--no-net",
        "--cmd-file", str(cmd_file),
        "--screenshot", str(screen_png),
        *extra_args,
    ]
    print(f"\n=== Starting {phase_name}: {' '.join(cmd)} ===", flush=True)
    t0 = time.time()
    with open(log_file, "wb") as lf:
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT)
        next_shot = 15
        while proc.poll() is None:
            elapsed = time.time() - t0
            if elapsed >= next_shot:
                with open(cmd_file, "a", encoding="utf-8") as cf:
                    cf.write(f"screenshot {screen_png}\n")
                st = subprocess.check_output(["du", "-sh", str(WIN_IMG)], text=True).split()[0]
                print(f"[{phase_name} +{int(elapsed)}s] running (windows11.img={st}, screen={screen_png.name})", flush=True)
                next_shot += 20
            if elapsed > max_minutes * 60:
                proc.terminate()
                raise TimeoutError(f"{phase_name} exceeded {max_minutes} minutes")
            time.sleep(2)
        if proc.returncode != 0:
            raise RuntimeError(f"{phase_name} exited with code {proc.returncode}; check {log_file}")
    print(f"=== {phase_name} finished cleanly in {int(time.time() - t0)}s! ===", flush=True)


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    installer_only = "--installer-only" in sys.argv
    if ISO is not None:
        if not ISO.exists():
            sys.exit(f"Missing {ISO}")
        print(f"Using ISO media: {ISO} (edition: {EDITION})", flush=True)
    elif not ESD.exists():
        sys.exit(f"Missing {ESD} (or set WINIOS_ISO=/path/to/Win11_Arm64.iso)")
    if not installer_only and not WINVM.exists():
        sys.exit(f"Missing {WINVM}")

    build_two_partition_installer()

    shutil.copyfile(qemu_firmware("edk2-aarch64-code.fd"), CODE_FD)
    shutil.copyfile(qemu_firmware("edk2-arm-vars.fd"), VARS_FD)

    if installer_only:
        stage_for_ipad()
        return

    if WIN_IMG.exists():
        WIN_IMG.unlink()
    with open(WIN_IMG, "wb") as f:
        f.truncate(DISK_GB * 1024 * 1024 * 1024)

    # Phase 1: Boot WinPE -> partition -> DISM unsplit install.wim -> offline reg + unattend -> bcdboot -> wpeutil shutdown
    run_winvm_phase("phase1_dism", ["--disk1", str(INST_IMG)], WORK / "prov_phase1.png", max_minutes=40)
    shutil.copyfile(VARS_FD, WORK / "vars_post_dism.fd")

    # Phase 2: Boot installed Windows 11 Pro ARM64 -> specialize -> reboot -> oobeSystem -> AutoLogon Ammaar -> clean shutdown
    run_winvm_phase("phase2_oobe", [], WORK / "prov_phase2.png", max_minutes=60)
    shutil.copyfile(VARS_FD, WORK / "vars_clean.fd")
    print("SUCCESS: Windows 11 Pro ARM64 provisioned and cleanly shut down!", flush=True)


if __name__ == "__main__":
    main()
