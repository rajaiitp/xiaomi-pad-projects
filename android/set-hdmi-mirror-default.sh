#!/usr/bin/env bash
# Set the Xiaomi Pad's Android HDMI mirroring preference through ADB.
# The default value 1 means accept mirroring without the confirmation prompt.
set -euo pipefail

serial=${ADB_SERIAL:-}
value=1

usage() {
  cat <<'EOF'
Usage: set-hdmi-mirror-default.sh [--serial SERIAL] [--disable]

Set Android's mirror_built_in_display secure setting on one authorized ADB device.
With no --serial, exactly one authorized device must be connected.
EOF
}

while (($#)); do
  case $1 in
    --serial)
      [[ $# -ge 2 ]] || {
        echo "--serial requires a value" >&2
        exit 2
      }
      serial=$2
      shift 2
      ;;
    --disable)
      value=0
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
  devices=()
  while IFS= read -r device; do
    [[ -n $device ]] && devices+=("$device")
  done < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  if ((${#devices[@]} != 1)); then
    echo "Expected exactly one authorized ADB device; use --serial SERIAL." >&2
    adb devices >&2
    exit 1
  fi
  serial=${devices[0]}
fi

adb_cmd=(adb -s "$serial")
"${adb_cmd[@]}" get-state >/dev/null
"${adb_cmd[@]}" shell settings put secure mirror_built_in_display "$value"

actual=$("${adb_cmd[@]}" shell settings get secure mirror_built_in_display | tr -d '\r')
if [[ $actual != "$value" ]]; then
  echo "Failed to set mirror_built_in_display on $serial (read back: $actual)" >&2
  exit 1
fi

if [[ $value == 1 ]]; then
  echo "HDMI mirroring confirmation disabled on $serial (mirror_built_in_display=1)."
else
  echo "HDMI mirroring confirmation restored on $serial (mirror_built_in_display=0)."
fi
