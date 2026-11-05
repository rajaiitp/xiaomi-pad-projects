#!/system/bin/sh
set -eu

# Android mksh marks extra descriptors close-on-exec, breaking descriptor locks.
ROOT_SHELL=/data/adb/magisk/busybox
if [ -x "$ROOT_SHELL" ] && [ "$(readlink /proc/$$/exe)" != "$(readlink -f "$ROOT_SHELL")" ]; then
  exec "$ROOT_SHELL" sh "$0" "$@"
fi

SERVICE=${CHARGE_LIMIT_SERVICE:-/data/adb/service.d/charge-threshold.sh}
STATE=${CHARGE_LIMIT_STATE:-/data/adb/charge-threshold}
SWITCH=${CHARGE_LIMIT_SWITCH:-/sys/class/power_supply/battery/battery_charging_enabled}
BACKUPS=${POWER_MODE_BACKUPS:-/data/adb/power-mode-backups}
MAX_LOCK_POLLS=25
LOCK_POLL_DELAY=0.2

[ "$(id -u)" = 0 ] || exit 1
umask 077
mkdir -p "$BACKUPS" "$STATE"
backup=$(mktemp -d "$BACKUPS/charge-limit.XXXXXX")
if [ -e "$SERVICE" ]; then
  cp -p "$SERVICE" "$backup/charge-threshold.sh"
  sync
  rm "$SERVICE"
  sync
fi
if [ -e "$STATE/paused" ]; then
  cp -p "$STATE/paused" "$backup/paused"
  sync
fi

pids=$(ps -A -o PID,ARGS | awk -v path="$SERVICE" '
  $2 ~ /(^|\/)(busybox|sh)$/ {
    if (($3 == "sh" && $4 == path && NF == 4) || ($3 == path && NF == 3)) print $1
  }
')
for pid in $pids; do
  children=$(ps -A -o PID,PPID,NAME | awk -v parent="$pid" '$2 == parent && $3 == "sleep" {print $1}')
  kill -TERM "$pid"
  for child in $children; do
    kill -TERM "$child" 2>/dev/null || true
  done
done

exec 9>"$STATE/service.lock"
attempt=0
until flock -n 9; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt "$MAX_LOCK_POLLS" ] || {
    printf 'Charge limiter still holds its lock\n' >&2
    exit 1
  }
  sleep "$LOCK_POLL_DELAY"
done
IFS= read -r current <"$SWITCH"
if [ "$current" != 1 ]; then
  printf '1\n' >"$SWITCH"
fi
IFS= read -r current <"$SWITCH"
[ "$current" = 1 ] || {
  printf 'Charging did not resume; backup=%s\n' "$backup" >&2
  exit 1
}
rm -f "$STATE/paused"
sync
printf 'charge_limit=100\ncharging_enabled=%s\nbackup=%s\n' "$current" "$backup"
