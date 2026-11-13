#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Live view of a long CI job, and a way to send it keystrokes.
#
#   ci_status.sh DIR [CMDFILE]
#
# 1. Every file in DIR becomes the whole content of the branch "ci-status" (one parentless commit,
#    force-pushed, so the branch never grows). DIR holds a small screenshot and a status text.
# 2. With CMDFILE: if the branch "ci-control" has a commands.txt this job has not applied yet, its
#    lines are appended to CMDFILE, the file build/winvm tails for input (click, type, enter ...).
#
# Never fails the step that calls it.
set -u
dir="$1"
cmdfile="${2:-}"
cd "$(dirname "$0")/../.." || exit 0
[ -d "$dir" ] || exit 0

state="${RUNNER_TEMP:-/tmp}/ci_status_state"
mkdir -p "$state"

push_status() {
  local idx="$state/index" tree commit f blob
  rm -f "$idx"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    blob="$(git hash-object -w "$f")" || return 0
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$blob,$(basename "$f")" || return 0
  done
  [ -f "$idx" ] || return 0
  tree="$(GIT_INDEX_FILE="$idx" git write-tree)" || return 0
  commit="$(git -c user.name="ci-status" -c user.email="ci-status@users.noreply.github.com" \
            commit-tree "$tree" -m "CI status (run ${GITHUB_RUN_NUMBER:-?})")" || return 0
  git push -q -f origin "$commit:refs/heads/ci-status" >/dev/null 2>&1 || echo "[status] push failed"
}

apply_control() {
  [ -n "$cmdfile" ] || return 0
  git fetch -q --depth 1 origin ci-control >/dev/null 2>&1 || return 0
  local id last
  id="$(git rev-parse -q --verify FETCH_HEAD:commands.txt 2>/dev/null)" || return 0
  last="$(cat "$state/control_applied" 2>/dev/null || true)"
  [ "$id" = "$last" ] && return 0
  echo "$id" > "$state/control_applied"
  echo "[control] applying commands.txt $id"
  { git cat-file blob "$id" | tr -d '\r'; echo; } >> "$cmdfile"
  git cat-file blob "$id" | sed -e 's/^/[control]   /'
  echo
}

apply_control
push_status
exit 0
