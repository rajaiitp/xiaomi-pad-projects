#!/usr/bin/env bash
# Install the tracked Xiaomi Pad HDMI/Termux stack through an authorized ADB link.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
serial=
install_apps=false
retire_notification=false
retire_hook=false

usage() {
  cat <<'EOF'
Usage: install-tablet-stack.sh [options]
  --serial SERIAL         select an ADB device
  --apps                  build and update both local HDMI APKs
  --retire-notification   remove the old Termux HDMI notification daemon/shortcuts
  --retire-hook           uninstall the redundant HDMI LSPosed app for user 0
EOF
}

while (($#)); do
  case $1 in
    --serial)
      serial=${2:?missing serial}
      shift 2
      ;;
    --apps)
      install_apps=true
      shift
      ;;
    --retire-notification)
      retire_notification=true
      shift
      ;;
    --retire-hook)
      retire_hook=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z $serial ]]; then
  mapfile -t devices < <(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
  ((${#devices[@]} == 1)) || {
    echo "Expected one authorized ADB device; use --serial." >&2
    adb devices >&2
    exit 1
  }
  serial=${devices[0]}
fi

adb_cmd=(adb -s "$serial")
"${adb_cmd[@]}" get-state >/dev/null

hdmi_script="$script_dir/../display/hdmi-panel-backlight.sh"
dispatcher="$script_dir/tablet-playback.sh"
sshd_script="$script_dir/termux-boot/start-sshd"
legacy_notification_dir="$script_dir/legacy-notification"
for file in \
  "$hdmi_script" \
  "$dispatcher" \
  "$sshd_script" \
  "$legacy_notification_dir/hdmi-controls-daemon" \
  "$legacy_notification_dir/move-hdmi" \
  "$legacy_notification_dir/move-tablet"; do
  [[ -f $file ]] || {
    echo "Missing source: $file" >&2
    exit 1
  }
  sh -n "$file"
done

stamp=$(date +%Y%m%d-%H%M%S)
stage=/data/local/tmp/tablet-stack-stage-$stamp
backup=/data/local/tmp/tablet-stack-backup-$stamp
"${adb_cmd[@]}" shell "mkdir -p '$stage'"
"${adb_cmd[@]}" push "$hdmi_script" "$stage/hdmi-panel-backlight.sh" >/dev/null
"${adb_cmd[@]}" push "$dispatcher" "$stage/tablet-playback" >/dev/null
"${adb_cmd[@]}" push "$sshd_script" "$stage/start-sshd" >/dev/null
"${adb_cmd[@]}" push \
  "$legacy_notification_dir/hdmi-controls-daemon" \
  "$stage/hdmi-controls-daemon" >/dev/null
"${adb_cmd[@]}" push "$legacy_notification_dir/move-hdmi" "$stage/move-hdmi" >/dev/null
"${adb_cmd[@]}" push "$legacy_notification_dir/move-tablet" "$stage/move-tablet" >/dev/null

retire_notification_int=$($retire_notification && echo 1 || echo 0)
retire_hook_int=$($retire_hook && echo 1 || echo 0)
"${adb_cmd[@]}" shell \
  "su -c 'sh -s -- $stage $backup $retire_notification_int $retire_hook_int'" <<'REMOTE_SCRIPT'
set -eu
stage=$1
backup=$2
retire_notification=$3
retire_hook=$4

mkdir -p "$backup"
for file in \
  /data/adb/service.d/hdmi-panel-backlight.sh \
  /data/adb/service.d/charge-threshold.sh \
  /data/data/com.termux/files/home/bin/tablet-playback \
  /data/data/com.termux/files/home/.termux/boot/start-sshd; do
  if [ -e "$file" ]; then
    cp -p "$file" "$backup/$(basename "$file")"
  fi
done
if [ -e /data/adb/tablet-playback ]; then
  cp -p /data/adb/tablet-playback "$backup/tablet-playback-root"
fi

termux_uid=$(stat -c %u:%g /data/data/com.termux)
cp "$stage/hdmi-panel-backlight.sh" /data/adb/service.d/hdmi-panel-backlight.sh
chmod 0755 /data/adb/service.d/hdmi-panel-backlight.sh
chown 0:0 /data/adb/service.d/hdmi-panel-backlight.sh
cp "$stage/tablet-playback" /data/data/com.termux/files/home/bin/tablet-playback
chmod 0755 /data/data/com.termux/files/home/bin/tablet-playback
chown "$termux_uid" /data/data/com.termux/files/home/bin/tablet-playback
cp "$stage/tablet-playback" /data/adb/tablet-playback
chmod 0755 /data/adb/tablet-playback
chown 0:0 /data/adb/tablet-playback
restorecon /data/adb/tablet-playback 2>/dev/null || true
cp "$stage/start-sshd" /data/data/com.termux/files/home/.termux/boot/start-sshd
chmod 0700 /data/data/com.termux/files/home/.termux/boot/start-sshd
chown "$termux_uid" /data/data/com.termux/files/home/.termux/boot/start-sshd

rm -f \
  /data/data/com.termux/files/home/.termux/boot/start-tailscale \
  /data/data/com.termux/files/home/.termux/boot/start-sshd.previous \
  /data/data/com.termux/files/home/.termux/start-sshd.previous \
  "/data/data/com.termux/files/home/.shortcuts/Move HDMI" \
  "/data/data/com.termux/files/home/.shortcuts/Move Tablet"

if [ "$retire_notification" = 1 ]; then
  cp -p /data/data/com.termux/files/home/.termux/boot/hdmi-controls-daemon "$backup/" 2>/dev/null || true
  rm -f \
    /data/data/com.termux/files/home/.termux/boot/hdmi-controls-daemon \
    /data/data/com.termux/files/home/.shortcuts/move-hdmi \
    /data/data/com.termux/files/home/.shortcuts/move-tablet \
    /data/data/com.termux/files/home/.termux/hdmi-status \
    /data/data/com.termux/files/home/.termux/hdmi-notification-state
else
  cp "$stage/hdmi-controls-daemon" /data/data/com.termux/files/home/.termux/boot/hdmi-controls-daemon
  cp "$stage/move-hdmi" /data/data/com.termux/files/home/.shortcuts/move-hdmi
  cp "$stage/move-tablet" /data/data/com.termux/files/home/.shortcuts/move-tablet
  chmod 0700 \
    /data/data/com.termux/files/home/.termux/boot/hdmi-controls-daemon \
    /data/data/com.termux/files/home/.shortcuts/move-hdmi \
    /data/data/com.termux/files/home/.shortcuts/move-tablet
  chown "$termux_uid" \
    /data/data/com.termux/files/home/.termux/boot/hdmi-controls-daemon \
    /data/data/com.termux/files/home/.shortcuts/move-hdmi \
    /data/data/com.termux/files/home/.shortcuts/move-tablet
fi

if [ "$retire_hook" = 1 ]; then
  pm uninstall --user 0 dev.raja.hdmidisplay >/dev/null 2>&1 || true
fi

rm -rf "$stage"
printf 'backup=%s\n' "$backup"
REMOTE_SCRIPT

if $install_apps; then
  "$script_dir/build-hdmi-control-tile.sh"
  "$script_dir/build-tv-touch-controller.sh"
  "${adb_cmd[@]}" install -r \
    "$script_dir/apps/hdmi-control-tile/build/hdmi-control-tile.apk" >/dev/null
  "${adb_cmd[@]}" install -r \
    "$script_dir/apps/tv-touch-controller/build/tv-touch-controller.apk" >/dev/null
fi

printf 'Installed tablet stack on %s. Scripts activate after their services restart.\n' "$serial"
if ! $retire_notification; then
  printf '%s\n' 'The notification daemon was preserved until the repaired tile is tested.'
fi
