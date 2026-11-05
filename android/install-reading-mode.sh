#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/.local/share/network-reticulum/toolchains/android-sdk"}}
adb_bin=${ADB:-"$sdk/platform-tools/adb"}
serial=''
ssh_host=xiaomi-tail

while (($#)); do
  case $1 in
    --serial)
      serial=${2:?missing serial}
      shift 2
      ;;
    --ssh)
      ssh_host=${2:?missing SSH host}
      shift 2
      ;;
    *)
      printf 'Usage: %s [--serial SERIAL] [--ssh HOST]\n' "$0" >&2
      exit 2
      ;;
  esac
done

if [[ -z $serial ]]; then
  mapfile -t devices < <("$adb_bin" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  ((${#devices[@]} == 1)) || {
    printf 'Select one authorized device with --serial\n' >&2
    exit 1
  }
  serial=${devices[0]}
fi
adb_cmd=("$adb_bin" -s "$serial")
"${adb_cmd[@]}" get-state >/dev/null
[[ $("${adb_cmd[@]}" shell getprop ro.product.device | tr -d '\r') = pipa ]] || {
  printf 'Reading Mode installation expects the Xiaomi Pad 6 (pipa)\n' >&2
  exit 1
}
sh -n "$script_dir/reading-mode.sh"
apk="$script_dir/apps/reading-mode/build/reading-mode.apk"
[[ -f $apk ]] || {
  printf 'Run build-reading-mode.sh first\n' >&2
  exit 1
}

stage=/data/local/tmp/reading-mode-stage-$(date +%Y%m%d-%H%M%S)-$$
cleanup() {
  "${adb_cmd[@]}" shell rm -rf "$stage" >/dev/null || printf 'Could not remove staging directory: %s\n' "$stage" >&2
}
trap cleanup EXIT
"${adb_cmd[@]}" shell mkdir "$stage"
"${adb_cmd[@]}" push "$script_dir/reading-mode.sh" "$stage/controller" >/dev/null
ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$ssh_host" \
  "/debug_ramdisk/su -c '/system/bin/sh -s -- $stage'" <<'REMOTE'
set -eu
PATH=/system/bin:/system/xbin
export PATH
stage=$1
controller=/data/adb/reading-mode-control
[ ! -e /data/adb/reading-mode/snapshot ] || {
  printf 'A Reading Mode snapshot exists; restore locally before updating\n' >&2
  exit 1
}
if [ -e "$controller" ]; then
  backup="$controller.backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$controller" "$backup"
  printf 'Controller backup: %s\n' "$backup"
fi
cp "$stage/controller" "$controller.new"
chown 0:0 "$controller.new"
chmod 0700 "$controller.new"
sh -n "$controller.new"
"$controller.new" check
[ "$("$controller.new" status)" = off ]
sync
mv "$controller.new" "$controller"
restorecon "$controller"
sync
printf 'Reading Mode controller is installed and off\n'
REMOTE
"${adb_cmd[@]}" install --no-incremental -r "$apk"
"${adb_cmd[@]}" shell cmd package resolve-activity --brief local.reading.mode
printf 'Reading Mode installed on %s. Open its setup app to approve Magisk and add the tile. Mode remains off.\n' "$serial"
