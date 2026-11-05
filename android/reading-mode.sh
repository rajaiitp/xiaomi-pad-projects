#!/system/bin/sh
set -eu

PATH=${READING_MODE_COMMAND_PATH:-/system/bin:/system/xbin}
export PATH
STATE_DIR=${READING_MODE_STATE_DIR:-/data/adb/reading-mode}
SNAPSHOT=$STATE_DIR/snapshot
SCHEMA_VERSION=1
MAX_POLLS=25
POLL_DELAY=0.2
BLUETOOTH_TIMEOUT_SECONDS=8
USER_ID=
STAGE=
ROLLBACK=0

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

read_value() {
  IFS= read -r value <"$1" || return 1
  printf '%s\n' "$value"
}

get_setting() {
  settings --user "$USER_ID" get "$1" "$2"
}

wait_setting() {
  namespace=$1 key=$2 expected=$3
  attempt=0
  while [ "$attempt" -lt "$MAX_POLLS" ]; do
    actual=$(get_setting "$namespace" "$key") || return 1
    [ "$actual" != "$expected" ] || return 0
    sleep "$POLL_DELAY"
    attempt=$((attempt + 1))
  done
  printf 'Setting did not settle: %s/%s expected %s, got %s\n' \
    "$namespace" "$key" "$expected" "$actual" >&2
  return 1
}

put_setting() {
  ns=$1 name=$2 desired=$3
  current=$(get_setting "$ns" "$name") || return 1
  [ "$current" != "$desired" ] || return 0
  if [ "$desired" = null ]; then
    settings --user "$USER_ID" delete "$ns" "$name" >/dev/null || return 1
  else
    settings --user "$USER_ID" put "$ns" "$name" "$desired" || return 1
  fi
  wait_setting "$ns" "$name" "$desired"
}

validate_value() {
  case "$1:$2" in
    user:*[!0-9]* | user:) return 1 ;;
    user:*) return 0 ;;
    night_display_auto_mode:0 | night_display_auto_mode:1 | night_display_auto_mode:2 | night_display_auto_mode:null) return 0 ;;
    night_display_activated:0 | night_display_activated:1 | night_display_activated:null) return 0 ;;
    wifi_scan_always_enabled:0 | wifi_scan_always_enabled:1 | wifi_scan_always_enabled:null) return 0 ;;
    ble_scan_always_enabled:0 | ble_scan_always_enabled:1 | ble_scan_always_enabled:null) return 0 ;;
    low_power:0 | low_power:1 | wifi_on:0 | wifi_on:1 | bluetooth_on:0 | bluetooth_on:1) return 0 ;;
    zen_mode:0 | zen_mode:1 | zen_mode:2 | zen_mode:3) return 0 ;;
    *) return 1 ;;
  esac
}

snapshot_setting() {
  saved=$(get_setting "$1" "$2") || return 1
  validate_value "$2" "$saved" || return 1
  printf '%s\n' "$saved" >"$STAGE/$2"
}

validate_snapshot() {
  [ -d "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || return 1
  [ "$(read_value "$SNAPSHOT/schema")" = "$SCHEMA_VERSION" ] || return 1
  for name in user night_display_auto_mode night_display_activated low_power \
    wifi_on bluetooth_on zen_mode wifi_scan_always_enabled ble_scan_always_enabled; do
    saved=$(read_value "$SNAPSHOT/$name") || return 1
    validate_value "$name" "$saved" || return 1
  done
  case $(read_value "$SNAPSHOT/phase") in
    prepared | on | restoring) ;;
    *) return 1 ;;
  esac
  USER_ID=$(read_value "$SNAPSHOT/user")
}

set_phase() {
  printf '%s\n' "$1" >"$SNAPSHOT/phase.new" || return 1
  sync || return 1
  mv "$SNAPSHOT/phase.new" "$SNAPSHOT/phase" || return 1
  sync
}

set_power() {
  before=$(get_setting global low_power) || return 1
  [ "$before" != "$1" ] || return 0
  cmd power set-mode "$1" >/dev/null || return 1
  wait_setting global low_power "$1"
}

set_wifi() {
  before=$(get_setting global wifi_on) || return 1
  [ "$before" != "$1" ] || return 0
  case $1 in
    0) cmd wifi set-wifi-enabled disabled >/dev/null || return 1 ;;
    1) cmd wifi set-wifi-enabled enabled >/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  wait_setting global wifi_on "$1"
}

set_bluetooth() {
  before=$(get_setting global bluetooth_on) || return 1
  if [ "$before" != "$1" ]; then
    case $1 in
      0) cmd bluetooth_manager disable >/dev/null || return 1 ;;
      1) cmd bluetooth_manager enable >/dev/null || return 1 ;;
      *) return 1 ;;
    esac
  fi
  wait_setting global bluetooth_on "$1" || return 1
  case $1 in
    0) timeout "$BLUETOOTH_TIMEOUT_SECONDS" cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null ;;
    1) timeout "$BLUETOOTH_TIMEOUT_SECONDS" cmd bluetooth_manager wait-for-state:STATE_ON >/dev/null ;;
    *) return 1 ;;
  esac
}

set_zen() {
  before=$(get_setting global zen_mode) || return 1
  [ "$before" != "$1" ] || return 0
  case $1 in
    0) filter=all ;;
    1) filter=priority ;;
    2) filter=none ;;
    3) filter=alarms ;;
    *) return 1 ;;
  esac
  cmd notification set_dnd "$filter" >/dev/null || return 1
  wait_setting global zen_mode "$1"
}

restore() {
  validate_snapshot || {
    printf 'Invalid snapshot; refusing to discard it\n' >&2
    return 1
  }
  set_phase restoring || return 1
  failed=0
  set_wifi "$(read_value "$SNAPSHOT/wifi_on")" || failed=1
  set_bluetooth "$(read_value "$SNAPSHOT/bluetooth_on")" || failed=1
  put_setting global wifi_scan_always_enabled "$(read_value "$SNAPSHOT/wifi_scan_always_enabled")" || failed=1
  put_setting global ble_scan_always_enabled "$(read_value "$SNAPSHOT/ble_scan_always_enabled")" || failed=1
  set_power "$(read_value "$SNAPSHOT/low_power")" || failed=1
  put_setting secure night_display_activated "$(read_value "$SNAPSHOT/night_display_activated")" || failed=1
  put_setting secure night_display_auto_mode "$(read_value "$SNAPSHOT/night_display_auto_mode")" || failed=1
  set_zen "$(read_value "$SNAPSHOT/zen_mode")" || failed=1
  [ "$failed" = 0 ] || {
    printf 'Restoration incomplete; snapshot retained\n' >&2
    return 1
  }
  rm -r "$SNAPSHOT" || return 1
  sync
}

finish() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$ROLLBACK" = 1 ]; then
    if ! restore; then
      printf 'Rollback incomplete; use the tile again to restore\n' >&2
    fi
    result=1
  fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
    rm -r "$STAGE" || result=1
  fi
  exit "$result"
}

activate_reading_mode() {
  USER_ID=$(cmd activity get-current-user) || return 1
  validate_value user "$USER_ID" || return 1
  STAGE=$(mktemp -d "$STATE_DIR/.prepare.XXXXXX") || return 1
  printf '%s\n' "$SCHEMA_VERSION" >"$STAGE/schema" || return 1
  printf '%s\n' "$USER_ID" >"$STAGE/user" || return 1
  printf 'prepared\n' >"$STAGE/phase" || return 1
  snapshot_setting secure night_display_auto_mode || return 1
  snapshot_setting secure night_display_activated || return 1
  for name in low_power wifi_on bluetooth_on zen_mode wifi_scan_always_enabled ble_scan_always_enabled; do
    snapshot_setting global "$name" || return 1
  done
  sync || return 1
  mv "$STAGE" "$SNAPSHOT" || return 1
  STAGE=
  # Publish and flush the complete snapshot before touching device settings.
  ROLLBACK=1
  sync || return 1
  put_setting secure night_display_auto_mode 0 || return 1
  put_setting secure night_display_activated 1 || return 1
  zen=$(get_setting global zen_mode) || return 1
  case $zen in
    0 | 1) set_zen 3 || return 1 ;;
    2 | 3) ;;
    *) return 1 ;;
  esac
  set_power 1 || return 1
  put_setting global wifi_scan_always_enabled 0 || return 1
  put_setting global ble_scan_always_enabled 0 || return 1
  set_bluetooth 0 || return 1
  set_wifi 0 || return 1
  set_phase on || return 1
  ROLLBACK=0
}

[ "$(id -u)" = 0 ] || fail 'Root access is required'
[ "$#" = 1 ] || fail 'Expected status, check, or toggle'
case $1 in
  status | check | toggle) ;;
  *) fail 'Unknown Reading Mode operation' ;;
esac

if [ "$1" = check ]; then
  for executable in settings cmd flock timeout sync mktemp; do
    command -v "$executable" >/dev/null || fail "Missing command: $executable"
  done
  printf 'ready\n'
  exit 0
fi

if [ "$1" = status ] && [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ]; then
  printf 'off\n'
  exit 0
fi

umask 077
[ ! -L "$STATE_DIR" ] || fail 'State directory must not be a symbolic link'
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || fail 'Reading Mode is busy'
trap finish EXIT
trap 'exit 1' HUP INT TERM

case $1 in
  status)
    validate_snapshot || fail 'Invalid Reading Mode snapshot'
    case $(read_value "$SNAPSHOT/phase") in
      on) printf 'on\n' ;;
      prepared | restoring) printf 'recovery\n' ;;
      *) fail 'Invalid Reading Mode phase' ;;
    esac
    ;;
  toggle)
    if [ -e "$SNAPSHOT" ]; then
      restore || fail 'Reading Mode restoration failed'
      printf 'off\n'
    else
      activate_reading_mode || fail 'Reading Mode activation failed'
      printf 'on\n'
    fi
    ;;
  *) fail 'Invalid Reading Mode operation' ;;
esac
