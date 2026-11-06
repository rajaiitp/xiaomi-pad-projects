#!/system/bin/sh
set -eu

# Android mksh closes extra descriptors when executing flock.
ROOT_SHELL=/data/adb/magisk/busybox
if [ -x "$ROOT_SHELL" ] && [ "$(readlink /proc/$$/exe)" != "$(readlink -f "$ROOT_SHELL")" ]; then
  exec "$ROOT_SHELL" sh "$0" "$@"
fi
PATH=${POWER_MODE_COMMAND_PATH:-/system/bin:/system/xbin}
export PATH
STATE=${POWER_MODE_STATE_DIR:-/data/adb/power-mode}
SETTINGS_LOCK=${POWER_MODE_SETTINGS_LOCK:-$STATE/../power-mode-settings.lock}
READING_SNAPSHOT=${POWER_MODE_READING_SNAPSHOT:-$STATE/../reading-mode/snapshot}
MEASUREMENT_TOOL=${POWER_MODE_MEASUREMENT_TOOL:-/data/adb/power-mode-measure}
MEASUREMENT_TIMEOUT=4
MEASUREMENT_ABORT_TIMEOUT=1
SNAPSHOT=$STATE/snapshot
ENABLED=$STATE/enabled
SCHEMA=1
MAX_POLLS=25
POLL_DELAY=0.2
BLUETOOTH_TIMEOUT=8
COMMAND_TIMEOUT=5
BROKER=0
STAGE=
NAMES='low_power wifi_scan_always_enabled ble_scan_always_enabled bluetooth_on wifi_on'

fail() {
  printf '%s\n' "$*" >&2
  return 1
}
read_value() { IFS= read -r value <"$1" && printf '%s\n' "$value"; }
run_measurement() (
  exec 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
  exec timeout -s KILL "$@"
)
measurement_requested() { [ -f "$STATE/measurement/armed" ] || [ -f "$STATE/measurement-monitor" ]; }
record_measurement() {
  measurement_requested || return 0
  if [ ! -x "$MEASUREMENT_TOOL" ]; then
    printf 'Measurement tool unavailable\n' >&2
    return 0
  fi
  if ! run_measurement "$MEASUREMENT_TIMEOUT" "$MEASUREMENT_TOOL" "$@" >/dev/null; then
    printf 'Measurement capture failed; Sleep mode restoration remains independent\n' >&2
    run_measurement "$MEASUREMENT_ABORT_TIMEOUT" "$MEASUREMENT_TOOL" abort capture_failed >/dev/null || true
  fi
}
get_value() { timeout "$COMMAND_TIMEOUT" settings get global "$1"; }
target() {
  case $1 in
    low_power) printf '1\n' ;;
    wifi_on | bluetooth_on | wifi_scan_always_enabled | ble_scan_always_enabled) printf '0\n' ;;
    *) return 1 ;;
  esac
}
valid_value() {
  case $1:$2 in
    low_power:0 | low_power:1 | wifi_on:0 | wifi_on:1 | bluetooth_on:0 | bluetooth_on:1) ;;
    wifi_scan_always_enabled:0 | wifi_scan_always_enabled:1 | wifi_scan_always_enabled:null) ;;
    ble_scan_always_enabled:0 | ble_scan_always_enabled:1 | ble_scan_always_enabled:null) ;;
    *) return 1 ;;
  esac
}
take_lock() {
  poll=0
  until flock -n "$1"; do
    poll=$((poll + 1))
    [ "$poll" -lt "$MAX_POLLS" ] || return 1
    sleep "$POLL_DELAY"
  done
}
lock() {
  [ ! -L "$SETTINGS_LOCK" ] || return 1
  exec 7>"$SETTINGS_LOCK"
  take_lock 7 || return 1
  exec 9>"$STATE/transaction.lock"
  if ! take_lock 9; then
    flock -u 7
    return 1
  fi
}
unlock() {
  flock -u 9
  flock -u 7
}
wait_value() {
  ns_name=$1 expected=$2 poll=0
  while [ "$poll" -lt "$MAX_POLLS" ]; do
    actual=$(get_value "$ns_name") || return 1
    [ "$actual" != "$expected" ] || return 0
    sleep "$POLL_DELAY"
    poll=$((poll + 1))
  done
  fail "Setting did not settle: $ns_name"
}
set_value() {
  setting=$1 desired=$2
  current=$(get_value "$setting") || return 1
  valid_value "$setting" "$current" || return 1
  if [ "$current" != "$desired" ]; then
    case $setting:$desired in
      low_power:0 | low_power:1) timeout "$COMMAND_TIMEOUT" cmd power set-mode "$desired" >/dev/null || return 1 ;;
      wifi_on:0) timeout "$COMMAND_TIMEOUT" cmd wifi set-wifi-enabled disabled >/dev/null || return 1 ;;
      wifi_on:1) timeout "$COMMAND_TIMEOUT" cmd wifi set-wifi-enabled enabled >/dev/null || return 1 ;;
      bluetooth_on:0) timeout "$COMMAND_TIMEOUT" cmd bluetooth_manager disable >/dev/null || return 1 ;;
      bluetooth_on:1) timeout "$COMMAND_TIMEOUT" cmd bluetooth_manager enable >/dev/null || return 1 ;;
      wifi_scan_always_enabled:null | ble_scan_always_enabled:null)
        timeout "$COMMAND_TIMEOUT" settings delete global "$setting" >/dev/null || return 1
        ;;
      wifi_scan_always_enabled:0 | wifi_scan_always_enabled:1 | ble_scan_always_enabled:0 | ble_scan_always_enabled:1)
        timeout "$COMMAND_TIMEOUT" settings put global "$setting" "$desired" || return 1
        ;;
      *) return 1 ;;
    esac
  fi
  wait_value "$setting" "$desired" || return 1
  case $setting:$desired in
    bluetooth_on:0) timeout "$BLUETOOTH_TIMEOUT" cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null ;;
    bluetooth_on:1) timeout "$BLUETOOTH_TIMEOUT" cmd bluetooth_manager wait-for-state:STATE_ON >/dev/null ;;
    *) return 0 ;;
  esac
}
validate_snapshot() {
  [ -d "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || return 1
  [ "$(read_value "$SNAPSHOT/schema")" = "$SCHEMA" ] || return 1
  case $(read_value "$SNAPSHOT/phase") in prepared | on | restoring) ;; *) return 1 ;; esac
  for name in $NAMES; do
    [ ! -L "$SNAPSHOT/$name" ] || return 1
    saved=$(read_value "$SNAPSHOT/$name") || return 1
    valid_value "$name" "$saved" || return 1
  done
}
phase() {
  printf '%s\n' "$1" >"$SNAPSHOT/phase.new" && sync &&
    mv "$SNAPSHOT/phase.new" "$SNAPSHOT/phase" && sync
}
restore() {
  [ -e "$SNAPSHOT" ] || [ -L "$SNAPSHOT" ] || return 0
  validate_snapshot || {
    fail 'Invalid snapshot retained'
    return 1
  }
  record_measurement end "${1:-rollback}"
  phase restoring || return 1
  failed=0
  for name in low_power wifi_on bluetooth_on wifi_scan_always_enabled ble_scan_always_enabled; do
    saved=$(read_value "$SNAPSHOT/$name") || return 1
    applied=$(target "$name") || return 1
    current=$(get_value "$name") || {
      failed=1
      continue
    }
    valid_value "$name" "$current" || {
      failed=1
      continue
    }
    # Restore only mutations we still own; preserve changes made by the user.
    if [ "$saved" != "$applied" ] && [ "$current" = "$applied" ]; then
      set_value "$name" "$saved" || failed=1
    fi
  done
  [ "$failed" = 0 ] || {
    fail 'Restoration incomplete; snapshot retained'
    return 1
  }
  rm -r "$SNAPSHOT" && sync
}
can_sleep() {
  [ "$BROKER" = 1 ] && [ -f "$ENABLED" ] || return 1
  [ ! -L "$ENABLED" ] && [ "$(read_value "$ENABLED")" = "$SCHEMA" ] || return 2
  if [ -e "$READING_SNAPSHOT" ] || [ -L "$READING_SNAPSHOT" ]; then return 1; fi
  power=$(dumpsys -t "$COMMAND_TIMEOUT" power) || return 2
  wake=$(printf '%s\n' "$power" | awk '/^  mWakefulness=/ {sub(/^.*=/, ""); print; exit}')
  case $wake in Asleep | Dozing) ;; Awake | Dreaming) return 1 ;; *) return 2 ;; esac
  battery=$(dumpsys -t "$COMMAND_TIMEOUT" battery) || return 2
  result=0
  printf '%s\n' "$battery" | awk '
    /powered:/ {
      if ($1 !~ /^(AC|USB|Wireless|Dock)$/ || $2 != "powered:" || $3 !~ /^(true|false)$/ || NF != 3 || seen[$1]++) invalid=1
      if ($3 == "true") powered=1
    }
    END {
      if (invalid || !seen["AC"] || !seen["USB"] || !seen["Wireless"]) exit 2
      exit(powered ? 1 : 0)
    }
  ' || result=$?
  [ "$result" = 0 ] || return "$result"
  display=$(dumpsys -t "$COMMAND_TIMEOUT" display) || return 2
  result=0
  printf '%s\n' "$display" | awk '
    /DisplayDeviceInfo/ {
      internal=($0 ~ /type (INTERNAL|BUILT_IN)([, }]|$)/)
      external=($0 ~ /HDMI|type EXTERNAL/)
      if (internal) found=1
      if (internal || external) {
        if ($0 !~ /state (ON|OFF|DOZE|DOZE_SUSPEND|ON_SUSPEND)([, }]|$)/) invalid=1
        if (external && $0 ~ /state (ON|DOZE|DOZE_SUSPEND|ON_SUSPEND)([, }]|$)/) active=1
      }
    }
    END {if (invalid || !found) exit 2; exit(active ? 1 : 0)}
  ' || result=$?
  return "$result"
}
apply() {
  if [ -e "$SNAPSHOT" ] || [ -L "$SNAPSHOT" ]; then
    validate_snapshot || return 1
    [ "$(read_value "$SNAPSHOT/phase")" = on ] && return 0
    restore || return 1
  fi
  STAGE=$(mktemp -d "$STATE/.prepare.XXXXXX") || return 1
  printf '%s\n' "$SCHEMA" >"$STAGE/schema" || return 1
  printf 'prepared\n' >"$STAGE/phase" || return 1
  for name in $NAMES; do
    saved=$(get_value "$name") || return 1
    valid_value "$name" "$saved" || return 1
    printf '%s\n' "$saved" >"$STAGE/$name" || return 1
  done
  sync && mv "$STAGE" "$SNAPSHOT" || return 1
  STAGE=
  if ! sync; then
    restore
    return 1
  fi
  for name in $NAMES; do
    guard=0
    can_sleep || guard=$?
    case $guard in
      0) ;;
      1)
        restore
        return $?
        ;;
      2)
        restore
        return 1
        ;;
      *) return 1 ;;
    esac
    if ! set_value "$name" "$(target "$name")"; then
      restore
      return 1
    fi
  done
  if ! phase on; then
    restore
    return 1
  fi
  guard=0
  can_sleep || guard=$?
  case $guard in 0) ;; 1)
    restore
    return $?
    ;;
  2)
    restore
    return 1
    ;;
  *) return 1 ;; esac
  if measurement_requested; then
    record_measurement start
    guard=0
    can_sleep || guard=$?
    case $guard in
      0) record_measurement accept ;;
      1) restore ineligible ;;
      2)
        restore unreadable
        return 1
        ;;
      *) return 1 ;;
    esac
  fi
}
reconcile() {
  guard=0
  can_sleep || guard=$?
  case $guard in
    0) apply ;;
    1) restore guard ;;
    2)
      restore unreadable
      fail 'Unreadable device guards'
      ;;
    *) return 1 ;;
  esac
}
controller_alive() {
  [ "$BROKER" != 1 ] || return 0
  exec 8>"$STATE/controller.lock"
  if flock -n 8; then
    flock -u 8
    return 1
  fi
  return 0
}
status() {
  if [ -e "$SNAPSHOT" ] || [ -L "$SNAPSHOT" ]; then
    validate_snapshot || return 1
    if [ "$(read_value "$SNAPSHOT/phase")" != on ] || ! controller_alive; then
      printf 'recovery\n'
      return
    fi
    printf 'sleeping\n'
  elif [ -f "$ENABLED" ]; then
    [ ! -L "$ENABLED" ] && [ "$(read_value "$ENABLED")" = "$SCHEMA" ] || return 1
    if controller_alive; then printf 'armed\n'; else printf 'stopped\n'; fi
  else
    printf 'off\n'
  fi
}
operation() {
  case $1 in
    enable)
      printf '%s\n' "$SCHEMA" >"$STATE/enabled.new" && sync &&
        mv "$STATE/enabled.new" "$ENABLED" && sync && reconcile
      ;;
    disable) restore disabled && rm -f "$ENABLED" && sync ;;
    reconcile) reconcile ;;
    recover)
      record_measurement abort recovery
      restore recovery
      ;;
    status) return 0 ;;
    *) fail 'Unknown operation' ;;
  esac
}
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$BROKER" = 1 ]; then
    if lock; then
      record_measurement abort disconnect
      restore disconnect || result=1
      unlock || result=1
    else result=1; fi
  fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -r "$STAGE" || result=1; fi
  exit "$result"
}

[ "$(id -u)" = 0 ] || {
  fail 'Root required'
  exit 1
}
[ "$#" = 1 ] || exit 1
case $1 in broker | enable | disable | reconcile | recover | status | check) ;; *) exit 1 ;; esac
if [ "$1" = check ]; then
  for executable in settings cmd dumpsys flock timeout sync mktemp; do command -v "$executable" >/dev/null || exit 1; done
  umask 077
  [ ! -L "$STATE" ] || exit 1
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  exec 9>"$STATE/capability.lock"
  flock -n 9 || {
    fail 'Shell does not preserve lock descriptors'
    exit 1
  }
  printf 'ready\n'
  exit 0
fi
umask 077
[ ! -L "$STATE" ] || exit 1
mkdir -p "$STATE"
chmod 700 "$STATE"
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ "$1" = broker ] || [ "$1" = recover ]; then
  exec 8>"$STATE/controller.lock"
  if ! flock -n 8; then
    if [ "$1" = recover ] && [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ]; then exit 0; fi
    fail 'Controller already running'
    exit 1
  fi
fi
if [ "$1" = broker ]; then
  BROKER=1
  lock || exit 1
  record_measurement abort startup
  restore startup && unlock || exit 1
  printf 'ready\n'
  while IFS= read -r request; do
    case $request in enable | disable | reconcile | status) ;; *) exit 1 ;; esac
    if ! lock; then
      printf 'error\n'
      continue
    fi
    if operation "$request"; then status || printf 'error\n'; else printf 'error\n'; fi
    unlock || exit 1
  done
else
  lock || exit 1
  operation "$1" || exit 1
  status
fi
