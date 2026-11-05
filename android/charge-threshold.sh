#!/system/bin/sh
# Xiaomi Pad 6 (pipa) charge threshold service for Magisk.
# Pause at 80%; resume at 75%, but only re-enable charging when this service
# previously disabled it.

BATTERY=/sys/class/power_supply/battery
SWITCH=$BATTERY/battery_charging_enabled
PAUSE_AT=80
RESUME_AT=75
STATE_DIR=/data/adb/charge-threshold
PAUSED_BY_SERVICE=$STATE_DIR/paused
LOG=$STATE_DIR/service.log
LOCK=$STATE_DIR/service.lock
MAX_LOG_BYTES=131072

umask 077
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK"
chmod 600 "$LOCK" 2>/dev/null || true
flock -n 9 || exit 0

read_file() {
  value=
  if [ -r "$1" ]; then
    IFS= read -r value <"$1" 2>/dev/null || true
  fi
  printf '%s' "$value"
}

rotate_log() {
  size=$(stat -c %s "$LOG" 2>/dev/null || printf 0)
  case "$size" in
    '' | *[!0-9]*) size=0 ;;
  esac
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    tail -n 500 "$LOG" >"$LOG.new" 2>/dev/null || : >"$LOG.new"
    mv -f "$LOG.new" "$LOG"
  fi
}

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

while [ "$(getprop sys.boot_completed)" != 1 ] || [ ! -e "$SWITCH" ]; do
  sleep 5
done

rotate_log

while true; do
  capacity=$(read_file "$BATTERY/capacity")
  current=$(read_file "$SWITCH")

  case "$capacity" in
    '' | *[!0-9]*) ;;
    *)
      if [ -f "$PAUSED_BY_SERVICE" ]; then
        if [ "$capacity" -le "$RESUME_AT" ]; then
          if [ "$current" != 1 ]; then
            printf '%s\n' 1 >"$SWITCH"
          fi
          rm -f "$PAUSED_BY_SERVICE"
          log "resumed at ${capacity}%"
        elif [ "$current" != 0 ]; then
          # Preserve the pause across a reboot or a driver reset until the
          # lower hysteresis threshold is reached.
          printf '%s\n' 0 >"$SWITCH"
        fi
      elif [ "$capacity" -ge "$PAUSE_AT" ] && [ "$current" = 1 ]; then
        printf '%s\n' 0 >"$SWITCH"
        : >"$PAUSED_BY_SERVICE"
        chmod 600 "$PAUSED_BY_SERVICE" 2>/dev/null || true
        log "paused at ${capacity}%"
      fi
      ;;
  esac

  sleep 30
done
