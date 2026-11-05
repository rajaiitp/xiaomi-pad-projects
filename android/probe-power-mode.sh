#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project="$script_dir/apps/power-mode"
toolchain="$HOME/.local/share/network-reticulum/toolchains"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$toolchain/android-sdk"}}
java_home=${JAVA_HOME_21:-${JAVA_HOME:-"$toolchain/jdk"}}
adb_bin=${ADB:-"$sdk/platform-tools/adb"}
serial=${1:?Usage: probe-power-mode.sh SERIAL}
platform="$sdk/platforms/android-37.0/android.jar"
output="$script_dir/power-mode/build/probe"
mkdir -p "$output/classes" "$output/dex"
"$java_home/bin/javac" -source 8 -target 8 -Xlint:all -Werror \
  -bootclasspath "$platform" -d "$output/classes" \
  "$project/probe/local/power/mode/research/FrameworkProbe.java"
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" \
  "$sdk/build-tools/36.0.0/d8" --lib "$platform" --min-api 28 --output "$output/dex" \
  "$output/classes/local/power/mode/research/FrameworkProbe.class"
"$adb_bin" -s "$serial" get-state | grep -qx device
remote=/data/local/tmp/power-mode-probe-$(date +%Y%m%d-%H%M%S)-$$.dex
cleanup() { "$adb_bin" -s "$serial" shell rm -f "$remote" >/dev/null; }
trap cleanup EXIT
"$adb_bin" -s "$serial" push "$output/dex/classes.dex" "$remote" >/dev/null
"$adb_bin" -s "$serial" shell -T su -c /data/adb/magisk/busybox sh -s -- "$remote" <<'DEVICE'
set -eu
[ "$(id -u)" = 0 ]
[ "$#" = 1 ]
pid=$(pidof system_server)
case $pid in '' | *' '*) exit 1 ;; esac
printf 'policy_capability=not_verified\npolicy_activation=not_attempted\n'
sha256sum /system/framework/services.jar /system/framework/framework.jar
if [ -d /data/adb/modules/zygisk_lsposed ]; then
  if [ -e /data/adb/modules/zygisk_lsposed/disable ]; then
    printf 'lsposed_module=disabled\n'
  else
    printf 'lsposed_module=enabled\n'
  fi
else
  printf 'lsposed_module=absent\n'
fi
magisk --sqlite 'SELECT key,value FROM settings WHERE key="zygisk";'
CLASSPATH=$1 app_process /system/bin local.power.mode.research.FrameworkProbe "$pid"
DEVICE
