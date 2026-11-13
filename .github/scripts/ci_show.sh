#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Print a phase's log tail and its screenshots into the job log.
#   ci_show.sh LOG PNG [PNG...]
# Screenshots go out as small base64 JPEGs between BEGIN/END markers, so the state of the guest
# screen can be read back from the plain-text job log.
log="$1"; shift
echo "::group::tail $log"
if [ -f "$log" ]; then
  grep -a -v -E "winvm: (cmd: )?screenshot" "$log" | tail -n 150
else
  echo "(no log)"
fi
echo "::endgroup::"
for png in "$@"; do
  if [ ! -f "$png" ]; then echo "(no screenshot $png)"; continue; fi
  jpg="${png%.png}.jpg"
  sips -s format jpeg -s formatOptions 50 -Z 1600 "$png" --out "$jpg" >/dev/null 2>&1 || cp "$png" "$jpg"
  echo "-----BEGIN SHOT $(basename "$png")-----"
  base64 -b 76 -i "$jpg"
  echo "-----END SHOT $(basename "$png")-----"
done
exit 0
