#!/system/bin/sh
# Xiaomi Pad 6 / LineageOS HDMI panel policy.
#
# Policies (stored in $PANEL_POLICY):
#   auto-off    turn the internal panel off shortly after HDMI connects
#   keep-on     keep it on for independent external-app mode
#   wake-on-key keep it off; touchscreen contact restores it temporarily

HDMI_STATUS=/sys/class/drm/card0-DP-1/status
BACKLIGHT=/sys/class/backlight/4-0011/brightness
STATE_DIR=/data/adb/hdmi-panel-backlight
SAVED_BRIGHTNESS=$STATE_DIR/saved_brightness
LAST_STATE=$STATE_DIR/last_state
PANEL_POLICY=$STATE_DIR/panel-policy
WAKE_UNTIL=$STATE_DIR/wake-until
LOG=$STATE_DIR/service.log
LOCK=$STATE_DIR/service.lock
TOUCH_FIFO=$STATE_DIR/touch-events
TERMUX_HDMI_STATUS=/data/data/com.termux/files/home/.termux/hdmi-status
DEFAULT_BRIGHTNESS=234
PANEL_OFF_DELAY=10
PANEL_WAKE_SECS=30
PANEL_WAKE_REFRESH_SECS=15
POLL_SECS=3
MAX_LOG_BYTES=262144

umask 077
mkdir -p "$STATE_DIR"
[ -f "$PANEL_POLICY" ] || printf '%s\n' auto-off >"$PANEL_POLICY"

# Prevent a manual restart from creating a second policy loop or input watcher.
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
    tail -n 1000 "$LOG" >"$LOG.new" 2>/dev/null || : >"$LOG.new"
    mv -f "$LOG.new" "$LOG"
  fi
}

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

restore_backlight() {
  restore=$(read_file "$SAVED_BRIGHTNESS")
  case "$restore" in
    '' | *[!0-9]* | 0) restore=$DEFAULT_BRIGHTNESS ;;
  esac
  printf '%s\n' "$restore" >"$BACKLIGHT"
}

publish_state() {
  next_state="$1"
  [ -n "$next_state" ] || return 0

  if [ "$next_state" != "$published_state" ]; then
    printf '%s\n' "$next_state" >"$STATE_DIR/hdmi-status"
    chmod 644 "$STATE_DIR/hdmi-status" 2>/dev/null || true
    published_state="$next_state"
  fi

  # Transitional compatibility for the notification daemon. This is written
  # only when the connector changes and can be removed after the tile is proven.
  if [ -z "$termux_uid" ] && [ -d /data/data/com.termux ]; then
    termux_uid=$(stat -c %u:%g /data/data/com.termux 2>/dev/null || true)
  fi
  if [ -n "$termux_uid" ] && [ "$next_state" != "$published_termux_state" ]; then
    mkdir -p "$(dirname "$TERMUX_HDMI_STATUS")"
    printf '%s\n' "$next_state" >"$TERMUX_HDMI_STATUS"
    chown "$termux_uid" "$TERMUX_HDMI_STATUS" 2>/dev/null || true
    chmod 600 "$TERMUX_HDMI_STATUS" 2>/dev/null || true
    published_termux_state="$next_state"
  fi
}

cleanup_touch_watcher() {
  if [ -n "$event_pid" ]; then
    kill "$event_pid" 2>/dev/null || true
    wait "$event_pid" 2>/dev/null || true
  fi
  rm -f "$TOUCH_FIFO"
}

# This watcher exists only while wake-on-key is active on a connected display.
# A FIFO lets the watcher terminate getevent cleanly instead of orphaning it.
touch_watcher() {
  rm -f "$TOUCH_FIFO"
  mkfifo "$TOUCH_FIFO" || exit 1
  event_pid=
  trap cleanup_touch_watcher EXIT INT TERM

  getevent -l >"$TOUCH_FIFO" 2>/dev/null &
  event_pid=$!
  while IFS= read -r event; do
    case "$event" in
      *BTN_TOUCH*DOWN*)
        [ "$(read_file "$HDMI_STATUS")" = connected ] || continue
        [ "$(read_file "$PANEL_POLICY")" = wake-on-key ] || continue

        now=$(date +%s)
        deadline=$(read_file "$WAKE_UNTIL")
        case "$deadline" in
          '' | *[!0-9]*) deadline=0 ;;
        esac
        if [ "$deadline" -lt $((now + PANEL_WAKE_REFRESH_SECS)) ]; then
          printf '%s\n' $((now + PANEL_WAKE_SECS)) >"$WAKE_UNTIL"
        fi

        brightness=$(read_file "$BACKLIGHT")
        if [ "$brightness" = 0 ]; then
          restore_backlight
          log "input woke panel for ${PANEL_WAKE_SECS}s"
        fi
        ;;
    esac
  done <"$TOUCH_FIFO"
}

touch_watcher_pid=
start_touch_watcher() {
  if [ -n "$touch_watcher_pid" ] && kill -0 "$touch_watcher_pid" 2>/dev/null; then
    return 0
  fi
  touch_watcher &
  touch_watcher_pid=$!
}

stop_touch_watcher() {
  if [ -n "$touch_watcher_pid" ]; then
    kill "$touch_watcher_pid" 2>/dev/null || true
    wait "$touch_watcher_pid" 2>/dev/null || true
    touch_watcher_pid=
  fi
}

cleanup() {
  stop_touch_watcher
  rm -f "$TOUCH_FIFO"
}
terminate() {
  cleanup
  exit 0
}
trap cleanup EXIT
trap terminate INT TERM

while [ "$(getprop sys.boot_completed)" != 1 ] || [ ! -e "$HDMI_STATUS" ] || [ ! -e "$BACKLIGHT" ]; do
  sleep 5
done

rotate_log
log "service started"
published_state=$(read_file "$STATE_DIR/hdmi-status")
published_termux_state=$(read_file "$TERMUX_HDMI_STATUS")
termux_uid=$(stat -c %u:%g /data/data/com.termux 2>/dev/null || true)
last=$(read_file "$LAST_STATE")

while true; do
  state=$(read_file "$HDMI_STATUS")
  policy=$(read_file "$PANEL_POLICY")
  case "$policy" in
    auto-off | keep-on | wake-on-key) ;;
    *) policy=auto-off ;;
  esac
  publish_state "$state"

  if [ "$state" = connected ] && [ "$policy" = wake-on-key ]; then
    start_touch_watcher
  else
    stop_touch_watcher
  fi

  case "$state" in
    connected)
      brightness=$(read_file "$BACKLIGHT")
      if [ "$last" != connected ]; then
        case "$brightness" in
          '' | *[!0-9]* | 0) ;;
          *) printf '%s\n' "$brightness" >"$SAVED_BRIGHTNESS" ;;
        esac
        last=connected
        printf '%s\n' "$last" >"$LAST_STATE"
        log "hdmi connected; saved brightness=${brightness:-unknown}"

        case "$policy" in
          wake-on-key)
            now=$(date +%s)
            printf '%s\n' $((now + PANEL_WAKE_SECS)) >"$WAKE_UNTIL"
            log "panel visible for initial ${PANEL_WAKE_SECS}s wake window"
            ;;
          keep-on) ;;
          auto-off)
            log "waiting ${PANEL_OFF_DELAY}s before turning panel backlight off"
            sleep "$PANEL_OFF_DELAY"
            state=$(read_file "$HDMI_STATUS")
            policy=$(read_file "$PANEL_POLICY")
            [ "$state" = connected ] || continue
            [ "$policy" = auto-off ] || continue
            brightness=$(read_file "$BACKLIGHT")
            ;;
        esac
      fi

      case "$policy" in
        keep-on)
          [ "$brightness" = 0 ] && restore_backlight
          ;;
        wake-on-key)
          deadline=$(read_file "$WAKE_UNTIL")
          now=$(date +%s)
          case "$deadline" in
            '' | *[!0-9]*) deadline=0 ;;
          esac
          if [ "$now" -lt "$deadline" ]; then
            [ "$brightness" = 0 ] && restore_backlight
          elif [ -n "$brightness" ] && [ "$brightness" != 0 ]; then
            printf '%s\n' 0 >"$BACKLIGHT"
            log "wake window expired; panel backlight off"
          fi
          ;;
        auto-off)
          if [ -n "$brightness" ] && [ "$brightness" != 0 ]; then
            printf '%s\n' 0 >"$BACKLIGHT"
            log "panel backlight off"
          fi
          ;;
      esac
      ;;
    *)
      if [ "$last" = connected ]; then
        restore_backlight
        last=disconnected
        printf '%s\n' "$last" >"$LAST_STATE"
        rm -f "$WAKE_UNTIL"
        log "hdmi disconnected; restored panel backlight"
      elif [ -z "$last" ]; then
        last=disconnected
        printf '%s\n' "$last" >"$LAST_STATE"
      fi
      ;;
  esac

  sleep "$POLL_SECS"
done
