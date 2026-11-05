#!/system/bin/sh
# Tablet playback and HDMI dispatcher. Invoked as root through SSH or Magisk su.
# Commands are received one per stdin line so URLs never become shell syntax.

set -eu
PATH=/system/bin:/system/xbin:/vendor/bin
PANEL_POLICY=/data/adb/hdmi-panel-backlight/panel-policy
WAKE_UNTIL=/data/adb/hdmi-panel-backlight/wake-until
HDMI_STATUS=/sys/class/drm/card0-DP-1/status
PANEL_WAKE_SECS=30
DISPLAY_SETTINGS=/data/system/display_settings.xml
export PATH

read_arg() {
  IFS= read -r value || value=
  printf '%s' "$value"
}

read_file() {
  value=
  if [ -r "$1" ]; then
    IFS= read -r value <"$1" 2>/dev/null || true
  fi
  printf '%s' "$value"
}

ACTION=$(read_arg)
ARGUMENT=$(read_arg)

launch() {
  am start --user 0 -W -n "$1" >/dev/null
}

external_display_id() {
  cmd display get-displays --type external -i | head -n 1
}

external_physical_display_id() {
  dumpsys SurfaceFlinger --display-id 2>/dev/null |
    awk '/Display [0-9]+.*pnpId=/ && $0 !~ /pnpId=QCM/ { print $2; exit }'
}

require_external_display() {
  if [ "$(read_file "$HDMI_STATUS")" != connected ]; then
    echo "HDMI is not connected" >&2
    return 1
  fi
  display_id=$(external_display_id)
  case "$display_id" in
    '' | *[!0-9]*)
      echo "No external display found" >&2
      return 1
      ;;
  esac
}

resumed_task_on_display() {
  target_display="$1"
  dumpsys activity activities |
    awk -v display="$target_display" '
      $0 ~ "^[[:space:]]*Display #" display "([^0-9]|$)" { on_display=1; next }
      /^[[:space:]]*Display #[0-9]+/ { on_display=0 }
      on_display && /Resumed: ActivityRecord/ && !/com.android.launcher3/ {
        if (match($0, / t[0-9]+/)) {
          print substr($0, RSTART + 2, RLENGTH - 2)
          exit
        }
      }'
}

move_current_task() {
  source_display="$1"
  target_display="$2"
  task=$(resumed_task_on_display "$source_display")
  case "$task" in
    '' | *[!0-9]*)
      echo "No movable app on display $source_display" >&2
      return 1
      ;;
  esac
  cmd activity display move-stack "$task" "$target_display"
}

move_state() {
  require_external_display >/dev/null 2>&1 || {
    echo disconnected
    return 1
  }
  if [ -n "$(resumed_task_on_display "$display_id")" ]; then
    echo hdmi
  else
    echo tablet
  fi
}

set_display_mode() {
  mode="$1"
  case "$mode" in
    external) desired=true ;;
    mirror) desired=false ;;
    *)
      echo "display mode must be external or mirror" >&2
      return 2
      ;;
  esac

  physical_id=$(external_physical_display_id)
  case "$physical_id" in
    '' | *[!0-9]*)
      echo "Connect HDMI before changing its persistent display mode" >&2
      return 1
      ;;
  esac
  target_name="local:$physical_id"

  workdir=/data/local/tmp/tablet-display-mode
  xml=$workdir/display_settings.xml
  updated=$workdir/display_settings.updated.xml
  abx=$workdir/display_settings.abx
  staged=$DISPLAY_SETTINGS.tablet-new
  backup=$DISPLAY_SETTINGS.tablet-backup
  mkdir -p "$workdir"
  [ -f "$DISPLAY_SETTINGS" ] || {
    echo "Display settings are missing" >&2
    return 1
  }
  [ -f "$backup" ] || cp -p "$DISPLAY_SETTINGS" "$backup"

  owner=$(stat -c %u:%g "$DISPLAY_SETTINGS")
  permissions=$(stat -c %a "$DISPLAY_SETTINGS")
  abx2xml "$DISPLAY_SETTINGS" "$xml"
  awk -v target="$target_name" -v desired="$desired" '
    index($0, "name=\"" target "\"") {
      found=1
      if ($0 ~ /shouldShowSystemDecors=\"(true|false)\"/) {
        sub(/shouldShowSystemDecors=\"(true|false)\"/,
            "shouldShowSystemDecors=\"" desired "\"")
      } else {
        sub(/[[:space:]]*\/>/, " shouldShowSystemDecors=\"" desired "\" />")
      }
    }
    { print }
    END { if (!found) exit 42 }
  ' "$xml" >"$updated" || {
    echo "External display $target_name was not found in display settings" >&2
    return 1
  }

  if cmp -s "$xml" "$updated"; then
    echo "$mode display mode is already staged"
    return 0
  fi

  xml2abx "$updated" "$abx"
  cp "$abx" "$staged"
  chown "$owner" "$staged"
  chmod "$permissions" "$staged"
  restorecon "$staged" 2>/dev/null || true
  mv -f "$staged" "$DISPLAY_SETTINGS"
  restorecon "$DISPLAY_SETTINGS" 2>/dev/null || true
}

case "$ACTION" in
  play-url)
    case "$ARGUMENT" in
      http://* | https://* | rtsp://* | rtmp://*) ;;
      *)
        echo "play-url accepts http(s), rtsp, or rtmp URLs only" >&2
        exit 2
        ;;
    esac
    am start --user 0 -W \
      -n org.videolan.vlc/.StartActivity \
      -a android.intent.action.VIEW \
      -d "$ARGUMENT" >/dev/null
    echo "Playing in VLC: $ARGUMENT"
    ;;
  open-url)
    case "$ARGUMENT" in
      http://* | https://*) ;;
      *)
        echo "open-url accepts http(s) URLs only" >&2
        exit 2
        ;;
    esac
    am start --user 0 -W -a android.intent.action.VIEW -d "$ARGUMENT" >/dev/null
    echo "Opened: $ARGUMENT"
    ;;
  hdmi-play-url)
    case "$ARGUMENT" in
      http://* | https://* | rtsp://* | rtmp://*) ;;
      *)
        echo "hdmi-play-url accepts http(s), rtsp, or rtmp URLs only" >&2
        exit 2
        ;;
    esac
    require_external_display
    am start --user 0 --display "$display_id" -W \
      -a android.intent.action.VIEW \
      -d "$ARGUMENT" \
      -t "video/*" \
      -p org.videolan.vlc >/dev/null
    echo "Playing on external display $display_id: $ARGUMENT"
    ;;
  stremio-url)
    case "$ARGUMENT" in
      stremio://*) ;;
      *)
        echo "stremio-url accepts stremio:// deep links only" >&2
        exit 2
        ;;
    esac
    am start --user 0 -W \
      -n com.stremio.one/com.stremio.android.MainActivity \
      -a android.intent.action.VIEW \
      -d "$ARGUMENT" >/dev/null
    echo "Opened in Stremio: $ARGUMENT"
    ;;
  launch)
    case "$ARGUMENT" in
      vlc) launch org.videolan.vlc/.StartActivity ;;
      stremio) launch com.stremio.one/com.stremio.android.MainActivity ;;
      moonlight) launch com.limelight/.PcView ;;
      *)
        echo "known apps: vlc, stremio, moonlight" >&2
        exit 2
        ;;
    esac
    echo "Launched: $ARGUMENT"
    ;;
  move-state)
    move_state
    ;;
  move-hdmi)
    require_external_display
    move_current_task 0 "$display_id"
    echo "Moved app to HDMI"
    ;;
  move-tablet)
    require_external_display
    move_current_task "$display_id" 0
    echo "Moved app to tablet"
    ;;
  move-toggle)
    require_external_display
    if [ -n "$(resumed_task_on_display "$display_id")" ]; then
      move_current_task "$display_id" 0
      echo "Moved app to tablet"
    else
      move_current_task 0 "$display_id"
      echo "Moved app to HDMI"
    fi
    ;;
  play | pause | play-pause | stop | next | previous | rewind | fast-forward)
    cmd media_session dispatch "$ACTION"
    echo "Media command: $ACTION"
    ;;
  volume)
    case "$ARGUMENT" in
      '' | *[!0-9]*)
        echo "volume requires an integer from 0 to 25" >&2
        exit 2
        ;;
    esac
    if [ "$ARGUMENT" -gt 25 ]; then
      echo "volume must be from 0 to 25" >&2
      exit 2
    fi
    cmd media_session volume --stream 3 --set "$ARGUMENT"
    ;;
  display-mode)
    set_display_mode "$ARGUMENT"
    echo "Staged $ARGUMENT display mode. Reboot to apply it."
    ;;
  reboot)
    echo "Rebooting tablet"
    reboot
    ;;
  hdmi)
    case "$ARGUMENT" in
      panel-on)
        printf '%s\n' keep-on >"$PANEL_POLICY"
        echo "Internal panel will stay on while HDMI is connected"
        ;;
      panel-auto-off)
        printf '%s\n' auto-off >"$PANEL_POLICY"
        echo "Internal panel will turn off while HDMI is connected"
        ;;
      wake-on-key)
        printf '%s\n' wake-on-key >"$PANEL_POLICY"
        printf '%s\n' $(($(date +%s) + PANEL_WAKE_SECS)) >"$WAKE_UNTIL"
        echo "Touchscreen input will wake the panel for ${PANEL_WAKE_SECS}s while HDMI is connected"
        ;;
      vlc | stremio | moonlight)
        require_external_display
        case "$ARGUMENT" in
          vlc) component=org.videolan.vlc/.StartActivity ;;
          stremio) component=com.stremio.one/com.stremio.android.MainActivity ;;
          moonlight) component=com.limelight/.PcView ;;
        esac
        am start --user 0 --display "$display_id" -W -n "$component" >/dev/null
        echo "Launched $ARGUMENT on external display $display_id"
        ;;
      *)
        echo "hdmi actions: moonlight, vlc, stremio, panel-on, panel-auto-off, wake-on-key" >&2
        exit 2
        ;;
    esac
    ;;
  status)
    printf 'HDMI: %s\n' "$(read_file "$HDMI_STATUS")"
    printf 'Panel backlight: %s\n' "$(read_file /sys/class/backlight/4-0011/brightness)"
    printf 'Panel policy: %s\n' "$(read_file "$PANEL_POLICY")"
    printf 'Media volume: '
    cmd media_session volume --stream 3 --get
    echo 'Sessions:'
    cmd media_session list-sessions
    ;;
  help | '')
    cat <<'EOF'
Usage:
  tablet play-url <http(s)|rtsp|rtmp URL>
  tablet open-url <http(s) URL>
  tablet stremio-url <stremio:// deep link>
  tablet hdmi-play-url <http(s)|rtsp|rtmp URL>
  tablet launch <vlc|stremio|moonlight>
  tablet <move-hdmi|move-tablet|move-toggle|move-state>
  tablet display-mode <external|mirror>  # takes effect after reboot
  tablet reboot
  tablet hdmi <moonlight|vlc|stremio|panel-on|panel-auto-off|wake-on-key>
  tablet <play|pause|play-pause|stop|next|previous|rewind|fast-forward>
  tablet volume <0-25>
  tablet status
EOF
    ;;
  *)
    echo "unknown command: $ACTION" >&2
    exit 2
    ;;
esac
