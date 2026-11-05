#!/system/bin/sh
set -eu
ROOT_SHELL=/data/adb/magisk/busybox
if [ -x "$ROOT_SHELL" ] && [ "$(readlink /proc/$$/exe)" != "$(readlink -f "$ROOT_SHELL")" ]; then
  exec "$ROOT_SHELL" sh "$0" "$@"
fi
PATH=${POWER_MODE_COMMAND_PATH:-/product/bin:/system_ext/bin:/system/bin:/system/xbin}
export PATH
CONTROL=${POWER_MODE_CONTROLLER:-/data/adb/power-mode-control}
STATE=${POWER_MODE_STATE_DIR:-/data/adb/power-mode}
MAINTENANCE=${POWER_MODE_MAINTENANCE_FILE:-/data/user_de/0/local.power.mode/files/maintenance}
BOOT_POLL_SECONDS=3
MAX_BOOT_POLLS=60
attempt=0
until [ "$(getprop sys.boot_completed)" = 1 ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt "$MAX_BOOT_POLLS" ] || exit 1
  sleep "$BOOT_POLL_SECONDS"
done
"$CONTROL" recover
[ ! -L "$STATE/enabled" ] || exit 1
[ -f "$STATE/enabled" ] || exit 0
IFS= read -r enabled <"$STATE/enabled"
[ "$enabled" = 1 ] || exit 1
[ ! -e "$MAINTENANCE" ] || exit 0
am start-foreground-service --user 0 -n local.power.mode/.StandbyService -a local.power.mode.RECONCILE >/dev/null
