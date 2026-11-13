#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CI check boot: start a Windows disk headless with networking on, wait for the desktop, type two
# commands (ver + ipconfig, then winver) and keep screenshots of each.
#
#   ci_phase3.sh DISK_IMG CODE_FD VARS_FD [DESKTOP_WAIT_MIN]
#
# VARS_FD is copied, so the file given stays as it was. A screenshot and a status text go out
# through ci_status.sh every minute.
set -uo pipefail
cd "$(dirname "$0")/../.."
W="$PWD/work"
disk="$1"; code="$2"; vars="$3"
wait_min="${4:-14}"
mkdir -p "$W/shots" "$W/status"
cmds="$W/phase3.cmds"
log="$W/phase3.log"
live="$W/phase3_live.png"
: > "$cmds"
cp "$vars" "$W/vars_phase3.fd"
cpus="$(sysctl -n hw.ncpu)"
[ "$cpus" -gt 4 ] && cpus=4
[ "$cpus" -lt 2 ] && cpus=2
limit=$(( (wait_min + 12) * 60 ))

HV_FLUSH=1 HV_SERIAL_STDERR=1 build/winvm --headless --code "$code" --vars "$W/vars_phase3.fd" --disk "$disk" \
  --cpus "$cpus" --ram 4096 --cmd-file "$cmds" --timeout "$limit" > "$log" 2>&1 &
pid=$!
t0=$(date +%s)

say()   { echo "$*" >> "$cmds"; }
alive() { kill -0 "$pid" 2>/dev/null; }
mins()  { echo $(( ($(date +%s) - t0) / 60 )); }
status() {
  say "screenshot $live"; sleep 3
  [ -f "$live" ] && sips -s format jpeg -s formatOptions 60 "$live" --out "$W/status/screen.jpg" >/dev/null 2>&1
  {
    echo "run ${GITHUB_RUN_NUMBER:-?} commit ${GITHUB_SHA:-unknown}"
    echo "phase phase3 (check boot)  elapsed $(mins) min  at $(date -u '+%Y-%m-%d %H:%M:%S UTC')  $*"
    echo
    echo "--- last lines of phase3.log ---"
    grep -a -v screenshot "$log" | tail -n 40
  } > "$W/status/status.txt"
  .github/scripts/ci_status.sh "$W/status" "$cmds"
}
keep() { say "screenshot $W/shots/$1.png"; sleep 4; }

while alive && [ "$(mins)" -lt "$wait_min" ]; do
  sleep 57
  status "waiting for the desktop"
  m="$(mins)"
  if [ $(( m % 4 )) -eq 0 ]; then keep "phase3_boot_$(printf '%02d' "$m")min"; fi
done

if alive; then
  keep phase3_desktop
  say "winr";  sleep 10
  say 'type cmd /k "ver & ipconfig"'; sleep 5
  say "enter"; sleep 45
  keep phase3_ver_ipconfig
  status "after ver + ipconfig"
  say "winr";  sleep 10
  say "type winver"; sleep 5
  say "enter"; sleep 30
  keep phase3_winver
  status "after winver"
  # Room for commands sent through the ci-control branch before the VM is stopped.
  for _ in 1 2 3; do sleep 50; alive || break; status "final minutes"; done
  keep phase3_final
  say "quit"
else
  echo "[phase3] the VM exited before the desktop check"
fi
wait "$pid"
echo "[phase3] winvm exit code: $?"
grep -a "winvm: stopped\|winvm: cpu\|SYSTEM_RESET" "$log" | tail -n 5
exit 0
