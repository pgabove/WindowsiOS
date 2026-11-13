#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""CI driver: run one phase of scripts/provision_windows_arm64.py as its own workflow step.

    ci_phase.py phase1 MINUTES    blank system disk + installer -> WinPE applies the image
    ci_phase.py phase2 MINUTES    first boot -> specialize -> OOBE -> first logon -> shutdown

The phases themselves are the provisioning script's own run_winvm_phase(). This driver only splits
them into steps, sizes the VM for the runner, checks how the VM stopped, and every two minutes
publishes a screenshot and a status text through ci_status.sh.
"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prov", ROOT / "scripts" / "provision_windows_arm64.py")
prov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prov)

STATUS_SH = ROOT / ".github" / "scripts" / "ci_status.sh"
STATUS_DIR = prov.WORK / "status"
SHOTS = prov.WORK / "shots"


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception as exc:  # status reporting must never stop the phase
        return f"({exc})"


def log_tail(log: Path, lines: int) -> str:
    if not log.exists():
        return "(no log yet)"
    text = log.read_bytes()[-200_000:].decode("utf-8", "replace")
    keep = [ln for ln in text.splitlines() if "screenshot" not in ln]
    return "\n".join(keep[-lines:])


def publish(tag: str, png: Path, log: Path, cmd_file: Path, t0: float, note: str = ""):
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    if png.exists():
        sh(f"sips -s format jpeg -s formatOptions 60 '{png}' --out '{STATUS_DIR / 'screen.jpg'}'")
    disk = sh(f"du -sh '{prov.WIN_IMG}' | cut -f1") if prov.WIN_IMG.exists() else "-"
    vm = sh("ps -axo rss=,%cpu=,etime=,comm= | grep '[w]invm'")
    swap = sh("sysctl -n vm.swapusage")
    free = sh("df -g / | tail -1")
    text = [
        f"run {os.environ.get('GITHUB_RUN_NUMBER', '?')} attempt {os.environ.get('GITHUB_RUN_ATTEMPT', '?')}"
        f" commit {os.environ.get('GITHUB_SHA', '?')[:12]}",
        f"phase {tag}  elapsed {int((time.time() - t0) // 60)} min  at {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}",
        f"windows11.img on disk: {disk}",
        f"winvm (rss KB, cpu %, elapsed): {vm}",
        f"host: {swap} | free disk {free}",
    ]
    if note:
        text.append(note)
    text += ["", f"--- last lines of {log.name} ---", log_tail(log, 60)]
    (STATUS_DIR / "status.txt").write_text("\n".join(text) + "\n", encoding="utf-8")
    out = sh(f"'{STATUS_SH}' '{STATUS_DIR}' '{cmd_file}'")
    if out:
        print(out, flush=True)


def watcher(tag: str, png: Path, log: Path, cmd_file: Path, stop: threading.Event):
    SHOTS.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    ticks = 0
    while not stop.wait(120):
        ticks += 1
        if ticks % 5 == 0 and png.exists():
            try:
                shutil.copyfile(png, SHOTS / f"{tag}_{int((time.time() - t0) // 60):03d}min.png")
            except OSError:
                pass
        publish(tag, png, log, cmd_file, t0)


def stop_reason(log: Path) -> str:
    text = log.read_bytes().decode("utf-8", "replace") if log.exists() else ""
    hits = re.findall(r"winvm: stopped \(([^)]*)\)", text)
    return hits[-1] if hits else "no stop line in the log"


def run_phase(tag: str, phase_name: str, extra_args, minutes: int):
    png = prov.WORK / f"prov_{tag}.png"
    log = prov.WORK / f"prov_{phase_name}.log"
    cmd_file = prov.WORK / f"prov_{phase_name}.cmds"
    # run_winvm_phase passes "--cpus 4"; a later "--cpus" wins. Hosted runners have 3 cores, and
    # four busy vCPU threads on three cores stall each other.
    cpus = max(2, min(4, os.cpu_count() or 4))
    stop = threading.Event()
    t0 = time.time()
    threading.Thread(target=watcher, args=(tag, png, log, cmd_file, stop), daemon=True).start()
    error = None
    try:
        prov.run_winvm_phase(phase_name, [*extra_args, "--cpus", str(cpus)], png, max_minutes=minutes)
    except Exception as exc:
        error = exc
    finally:
        stop.set()
    if error is not None:
        time.sleep(8)  # a terminated winvm flushes its disk and writes its last log lines
    reason = stop_reason(log)
    resets = log.read_bytes().count(b"PSCI SYSTEM_RESET") if log.exists() else 0
    summary = f"{tag}: VM stop reason '{reason}', {resets} guest reboot(s), {int(time.time() - t0)} s"
    if error is None and reason != "halt":
        error = RuntimeError(f"the VM did not power off cleanly ({reason})")
    publish(tag, png, log, cmd_file, t0, note=f"RESULT {summary}" + (f" ERROR {error}" if error else " OK"))
    print(summary, flush=True)
    if error is not None:
        print(f"::error::{tag} failed: {error}", flush=True)
        sys.exit(1)


def main():
    phase, minutes = sys.argv[1], int(sys.argv[2])
    os.environ.setdefault("HV_FLUSH", "1")          # as the iOS build: no fsync per guest flush
    os.environ.setdefault("HV_SERIAL_STDERR", "1")  # firmware console into the phase log
    if phase == "phase1":
        if prov.WIN_IMG.exists():
            prov.WIN_IMG.unlink()
        with open(prov.WIN_IMG, "wb") as f:
            f.truncate(prov.DISK_GB * 1024 * 1024 * 1024)
        run_phase("phase1", "phase1_dism", ["--disk1", str(prov.INST_IMG)], minutes)
        used_gb = int(sh(f"du -sk '{prov.WIN_IMG}' | cut -f1") or 0) / (1 << 20)
        print(f"windows11.img holds {used_gb:.1f} GB after phase 1", flush=True)
        if used_gb < 6:
            print("::error::phase 1 ended without a Windows image on the system disk", flush=True)
            sys.exit(1)
        shutil.copyfile(prov.VARS_FD, prov.WORK / "vars_post_dism.fd")
    elif phase == "phase2":
        run_phase("phase2", "phase2_oobe", [], minutes)
        shutil.copyfile(prov.VARS_FD, prov.WORK / "vars_clean.fd")
        print("SUCCESS: Windows provisioned and cleanly shut down", flush=True)
    else:
        sys.exit(f"unknown phase {phase}")


if __name__ == "__main__":
    main()
