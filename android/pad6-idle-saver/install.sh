#!/usr/bin/env bash
# Install/update the Pad 6 idle-saver Magisk service over ADB.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERIAL="${1:-${ANDROID_SERIAL:-}}"
[[ -n $SERIAL ]] || {
  printf 'Usage: %s SERIAL (or set ANDROID_SERIAL)\n' "$0" >&2
  exit 2
}
ADB=(adb -s "$SERIAL")
REMOTE_SERVICE="/data/adb/service.d/99-pad6-idle-saver.sh"
REMOTE_BASE="/data/adb/pad6-idle-saver"
REMOTE_TMP="/data/local/tmp/99-pad6-idle-saver.sh"

"${ADB[@]}" get-state | grep -qx device
"${ADB[@]}" push "$ROOT/service.sh" "$REMOTE_TMP" >/dev/null
"${ADB[@]}" shell "su -c '
  set -e
  if [ -r $REMOTE_BASE/pid ]; then
    old_pid=\$(cat $REMOTE_BASE/pid 2>/dev/null || true)
    [ -z \"\$old_pid\" ] || kill \"\$old_pid\" 2>/dev/null || true
  fi
  mkdir -p /data/adb/service.d $REMOTE_BASE
  cp $REMOTE_TMP $REMOTE_SERVICE
  chown root:root $REMOTE_SERVICE
  chmod 700 $REMOTE_SERVICE
  rm -f $REMOTE_TMP
  nohup $REMOTE_SERVICE </dev/null >/dev/null 2>&1 &
'"

sleep 1
printf 'Installed %s on %s\n\n' "$REMOTE_SERVICE" "$SERIAL"
"${ADB[@]}" shell "su -c '$REMOTE_SERVICE --status'"
