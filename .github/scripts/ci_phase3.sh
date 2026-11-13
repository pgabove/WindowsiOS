#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CI check boot: start a Windows disk headless with networking on, wait for the desktop, then look
# at it and keep screenshots.
#
#   ci_phase3.sh DISK_IMG CODE_FD VARS_FD [DESKTOP_WAIT_MIN]
#
# Environment:
#   PHASE3_TAG=name      names the log and screenshots (work/phase3_<name>.log, shots/phase3_<name>_*.png)
#   PHASE3_FB=WxH        screen resolution to ask the firmware for (winvm --fb)
#   PHASE3_TESTS=full    type checks into Windows: network, internet, driver log, setup summary, winver
#                =look   only screenshots (e.g. to see the display scaling after a resolution change)
#
# VARS_FD is copied, so the file given stays as it was. A screenshot and a status text go out
# through ci_status.sh every minute.
set -uo pipefail
cd "$(dirname "$0")/../.."
W="$PWD/work"
disk="$1"; code="$2"; vars="$3"
wait_min="${4:-14}"
tag="${PHASE3_TAG:-check}"
tests="${PHASE3_TESTS:-full}"
mkdir -p "$W/shots" "$W/status"
cmds="$W/phase3_$tag.cmds"
log="$W/phase3_$tag.log"
live="$W/phase3_live.png"
: > "$cmds"
cp "$vars" "$W/vars_phase3_$tag.fd"
cpus="$(sysctl -n hw.ncpu)"
[ "$cpus" -gt 4 ] && cpus=4
[ "$cpus" -lt 2 ] && cpus=2
limit=$(( (wait_min + 12) * 60 ))
fb=()
[ -n "${PHASE3_FB:-}" ] && fb=(--fb "$PHASE3_FB")

HV_FLUSH=1 HV_SERIAL_STDERR=1 build/winvm --headless --code "$code" --vars "$W/vars_phase3_$tag.fd" --disk "$disk" \
  --cpus "$cpus" --ram 4096 ${fb[@]+"${fb[@]}"} --cmd-file "$cmds" --timeout "$limit" > "$log" 2>&1 &
pid=$!
t0=$(date +%s)

say()   { echo "$*" >> "$cmds"; }
alive() { kill -0 "$pid" 2>/dev/null; }
mins()  { echo $(( ($(date +%s) - t0) / 60 )); }
status() {
  say "screenshot $live"; sleep 3
  [ -f "$live" ] && sips -s format jpeg -s formatOptions 60 -Z 1400 "$live" --out "$W/status/screen.jpg" >/dev/null 2>&1
  {
    echo "run ${GITHUB_RUN_NUMBER:-?} commit ${GITHUB_SHA:-unknown}"
    echo "phase phase3 $tag ${PHASE3_FB:-default} (check boot)  elapsed $(mins) min  at $(date -u '+%Y-%m-%d %H:%M:%S UTC')  $*"
    echo
    echo "--- last lines of phase3_$tag.log ---"
    grep -a -v screenshot "$log" | tail -n 40
  } > "$W/status/status.txt"
  .github/scripts/ci_status.sh "$W/status" "$cmds"
}
keep() { say "screenshot $W/shots/phase3_${tag}_$1.png"; sleep 4; }

while alive && [ "$(mins)" -lt "$wait_min" ]; do
  sleep 57
  status "waiting for the desktop"
  m="$(mins)"
  if [ $(( m % 4 )) -eq 0 ]; then keep "boot_$(printf '%02d' "$m")min"; fi
done

if alive && [ "$tests" = full ]; then
  keep desktop
  say "winr";  sleep 10
  say 'type cmd /k "ver & type C:\WinIOS\setup-summary.txt & findstr /i /c:netkvm C:\Drivers\pnputil.log & ipconfig | findstr /c:adapter /c:IPv4 & curl -s -m 20 http://www.msftconnecttest.com/connecttest.txt"'; sleep 5
  say "enter"; sleep 50
  keep checks
  status "after the network and setup checks"
  say "winr";  sleep 10
  say "type winver"; sleep 5
  say "enter"; sleep 30
  keep winver
  status "after winver"
  # Room for commands sent through the ci-control branch before the VM is stopped.
  for _ in 1 2 3; do sleep 50; alive || break; status "final minutes"; done
  keep final
  say "quit"
elif alive; then
  keep desktop
  for _ in 1 2 3 4; do sleep 55; alive || break; status "looking"; done
  keep final
  say "quit"
else
  echo "[phase3 $tag] the VM exited before the desktop check"
fi
wait "$pid"
echo "[phase3 $tag] winvm exit code: $?"
grep -a "winvm: stopped\|winvm: cpu\|SYSTEM_RESET\|asking the firmware\|ramfb configured" "$log" | tail -n 8
exit 0
