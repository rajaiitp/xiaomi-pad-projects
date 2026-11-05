#!/usr/bin/env bash
set -euo pipefail
umask 077
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project="$script_dir/apps/power-mode"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/.local/share/network-reticulum/toolchains/android-sdk"}}
java_home=${JAVA_HOME_21:-${JAVA_HOME:-"$HOME/.local/share/network-reticulum/toolchains/jdk"}}
adb_bin=${ADB:-"$sdk/platform-tools/adb"}
signer="$sdk/build-tools/36.0.0/apksigner"
serial=${1:?Usage: install-power-mode.sh SERIAL}
apk="$project/build/power-mode.apk"
[[ -f $apk ]] || {
  printf 'Build Sleep mode first\n' >&2
  exit 1
}
"$adb_bin" -s "$serial" get-state | grep -qx device
installed=$("$adb_bin" -s "$serial" shell pm path --user 0 local.power.mode | tr -d '\r')
[[ $installed == package:* && $installed != *$'\n'* ]] || {
  printf 'Expected one installed helper APK for a verified upgrade\n' >&2
  exit 1
}
mkdir -p "$script_dir/../local/backups"
backup=$(mktemp -d "$script_dir/../local/backups/sleep-mode.XXXXXX")
"$adb_bin" -s "$serial" pull "${installed#package:}" "$backup/app.apk" >/dev/null
certificate() {
  JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" "$signer" verify --print-certs "$1" |
    awk '/^Signer #1 certificate SHA-256 digest:/ {print $NF}'
}
old_certificate=$(certificate "$backup/app.apk")
new_certificate=$(certificate "$apk")
[[ -n $old_certificate && $old_certificate == "$new_certificate" ]] || {
  printf 'APK signing identity mismatch; no device changes made\n' >&2
  exit 1
}
stage=/data/local/tmp/power-mode-install-$(date +%Y%m%d-%H%M%S)-$$
success=0
cleanup() {
  if [[ $success == 1 ]]; then
    "$adb_bin" -s "$serial" shell su -c /data/adb/magisk/busybox rm -rf "$stage" >/dev/null
  else printf 'Installation did not complete; retain stage=%s and backup=%s\n' "$stage" "$backup" >&2; fi
}
trap cleanup EXIT
"$adb_bin" -s "$serial" shell mkdir "$stage"
for entry in "power-mode/power-mode-control.sh:controller" "power-mode/recover-on-boot.sh:recover" \
  "power-mode/install-pipa.sh:install" "reading-mode.sh:reading"; do
  "$adb_bin" -s "$serial" push "$script_dir/${entry%:*}" "$stage/${entry#*:}" >/dev/null
done
"$adb_bin" -s "$serial" push "$apk" "$stage/app.apk" >/dev/null
"$adb_bin" -s "$serial" shell -T su -c /data/adb/magisk/busybox sh "$stage/install" "$stage"
success=1
printf 'Host rollback APK: %s/app.apk\n' "$backup"
