#!/usr/bin/env bash
# Stop and remove the Pad 6 idle-saver Magisk service over ADB.
set -euo pipefail

SERIAL="${1:-${ANDROID_SERIAL:-}}"
[[ -n $SERIAL ]] || {
  printf 'Usage: %s SERIAL (or set ANDROID_SERIAL)\n' "$0" >&2
  exit 2
}
ADB=(adb -s "$SERIAL")
REMOTE_SERVICE="/data/adb/service.d/99-pad6-idle-saver.sh"
REMOTE_BASE="/data/adb/pad6-idle-saver"

"${ADB[@]}" get-state | grep -qx device
"${ADB[@]}" shell "su -c '
  managed=0
  [ -r $REMOTE_BASE/managed-battery-saver ] && managed=\$(cat $REMOTE_BASE/managed-battery-saver)
  if [ -r $REMOTE_BASE/pid ]; then
    old_pid=\$(cat $REMOTE_BASE/pid 2>/dev/null || true)
    [ -z \"\$old_pid\" ] || kill \"\$old_pid\" 2>/dev/null || true
  fi
  cmd deviceidle unforce >/dev/null 2>&1 || true
  if [ \"\$managed\" = 1 ]; then cmd power set-mode 0 >/dev/null 2>&1 || settings put global low_power 0; fi
  rm -f $REMOTE_SERVICE
  rm -rf $REMOTE_BASE
'"
printf 'Removed Pad 6 idle-saver from %s\n' "$SERIAL"
