#!/system/bin/sh
set -eu
ROOT_SHELL=/data/adb/magisk/busybox
if [ -x "$ROOT_SHELL" ] && [ "$(readlink /proc/$$/exe)" != "$(readlink -f "$ROOT_SHELL")" ]; then
  exec "$ROOT_SHELL" sh "$0" "$@"
fi
exec 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
PATH=${POWER_MODE_COMMAND_PATH:-/system/bin:/system/xbin}
LC_ALL=C
export PATH LC_ALL
STATE=${POWER_MODE_STATE_DIR:-/data/adb/power-mode}
DIRECTORY=$STATE/measurement
HISTORY=$STATE/measurement-history
MONITOR=$STATE/measurement-monitor
ADMISSION=$STATE/measurement-admission
SEQUENCE=$STATE/measurement-sequence
CLOCK=$STATE/measurement-clock
HEALTH=$STATE/measurement-error
SKIP=$STATE/measurement-skip
ROOT=${POWER_MODE_MEASUREMENT_ROOT:-}
SNAPSHOT=$STATE/snapshot
COMMAND_TIMEOUT=1
SCHEMA=1
RETENTION_DAYS=7
SECONDS_PER_DAY=86400
MAX_HISTORY_RECORDS=512
MAX_HISTORY_KIB=131072
SESSION_RESERVE_KIB=16384
METADATA_RESERVE_KIB=64
MAX_PRUNE_BATCH=8
MAX_DUMP_BYTES=262144
OUTPUT_LIMIT_BLOCKS=1024
MAX_SEQUENCE=2147483646
STAGE=
AGE=
ADMIT_ID=
ADMIT_BOOT=
ADMIT_TRANSACTION=

read_value() { [ ! -L "$1" ] && IFS= read -r value <"$1" && printf '%s\n' "$value"; }
unsigned() { case $1 in '' | *[!0-9]*) return 1 ;; *) [ "${#1}" -le 12 ] ;; esac }
atomic() {
  path=$1
  shift
  printf '%s\n' "$@" >"$path.new" && sync && mv "$path.new" "$path" && sync
}
set_phase() { atomic "$DIRECTORY/phase" "$1"; }
uptime_to() { awk '{print $1}' "$ROOT/proc/uptime" >"$1"; }
transaction() { stat -c '%d:%i:%y:%z' "$SNAPSHOT"; }
monitor_enabled() {
  [ -f "$MONITOR" ] || return 1
  [ "$(read_value "$MONITOR")" = "$SCHEMA:$RETENTION_DAYS" ] || return 2
}
clock_age() {
  [ -z "$AGE" ] || return 0
  boot=$(read_value "$ROOT/proc/sys/kernel/random/boot_id") || return 1
  [ -n "$boot" ] || return 1
  mono=$(awk '{printf "%.0f\n", int($1)}' "$ROOT/proc/uptime") || return 1
  unsigned "$mono" || return 1
  age=0
  if [ -e "$CLOCK" ]; then
    { IFS= read -r previous_boot && IFS= read -r previous_mono && IFS= read -r age; } <"$CLOCK" || return 1
    unsigned "$previous_mono" && unsigned "$age" || return 1
    if [ "$previous_boot" = "$boot" ]; then
      if [ "$mono" -ge "$previous_mono" ]; then age=$((age + mono - previous_mono)); else mono=$previous_mono; fi
    else
      # Unobserved time between boots is excluded; wall-clock jumps cannot expire data early.
      age=$((age + mono))
    fi
  fi
  atomic "$CLOCK" "$boot" "$mono" "$age" || return 1
  AGE=$age
}
close_fields() {
  clock_age || return 1
  atomic "$1/closed_age_s" "$AGE" || return 1
  date -u +%Y-%m-%dT%H:%M:%SZ >"$1/closed_utc"
}
stop() {
  printf '%s\n' "$1" >"$DIRECTORY/reason" || return 1
  close_fields "$DIRECTORY" || return 1
  set_phase failed || return 1
  rm -f "$DIRECTORY/armed"
  sync
}
finish() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$result" != 0 ] && [ ! -e "$HEALTH" ]; then printf 'recorder_operation_failed\n' >"$HEALTH" || true; fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
    if [ ! -f "$DIRECTORY/phase" ] || [ "$(read_value "$DIRECTORY/phase")" != failed ]; then stop interrupted_capture || result=1; fi
    rm -rf "$STAGE" || result=1
  fi
  exit "$result"
}
new_record() {
  number=0
  if [ -e "$SEQUENCE" ]; then
    number=$(read_value "$SEQUENCE")
    unsigned "$number" || return 1
  elif [ -d "$HISTORY" ]; then
    for item in "$HISTORY"/session.*; do [ ! -e "$item" ] || return 1; done
  fi
  [ "$number" -lt "$MAX_SEQUENCE" ] || return 1
  number=$((number + 1))
  atomic "$SEQUENCE" "$number" || return 1
  mkdir -p "$HISTORY"
  RECORD=$(mktemp -d "$HISTORY/session.$(printf '%010d' "$number").XXXXXX")
}
valid_id() {
  case $1 in session.*) ;; *) return 1 ;; esac
  case $1 in *[!a-zA-Z0-9.]*) return 1 ;; esac
}
load_admission() {
  admission_file=${1:-$ADMISSION}
  [ -f "$admission_file" ] && [ ! -L "$admission_file" ] || return 1
  { IFS= read -r ADMIT_ID && IFS= read -r ADMIT_BOOT && IFS= read -r ADMIT_TRANSACTION; } <"$admission_file" || return 2
  valid_id "$ADMIT_ID" && [ -n "$ADMIT_BOOT" ] && [ -n "$ADMIT_TRANSACTION" ] || return 2
  [ -d "$HISTORY/$ADMIT_ID" ] && [ ! -L "$HISTORY/$ADMIT_ID" ] || return 2
}
current_owner() {
  if [ -e "$DIRECTORY/admission_id" ]; then read_value "$DIRECTORY/admission_id"; else printf '\n'; fi
}
fail_admission() {
  reason=$1
  if [ "$(current_owner)" = "$ADMIT_ID" ]; then
    current_phase=$(read_value "$DIRECTORY/phase") || current_phase=unknown
    case $current_phase in complete | failed) return 0 ;; *)
      stop "$reason"
      return $?
      ;;
    esac
  fi
  failed=$HISTORY/$ADMIT_ID/measurement
  if [ ! -e "$failed" ]; then
    mkdir "$failed"
    printf '%s\n' "$SCHEMA" >"$failed/schema"
    printf '%s\n' "$reason" >"$failed/reason"
    printf '%s\n' "$ADMIT_ID" >"$failed/admission_id"
    printf '%s\n' "$ADMIT_ID" "$ADMIT_BOOT" "$ADMIT_TRANSACTION" >"$failed/admission"
    close_fields "$failed"
    atomic "$failed/phase" failed
  fi
}
resolve_pending_admission() {
  [ ! -e "$ADMISSION.new" ] || {
    [ ! -L "$ADMISSION.new" ] || return 1
    load_admission "$ADMISSION.new"
    fail_admission interrupted_admission
    mv "$ADMISSION.new" "$ADMISSION"
    sync
  }
}
archive_current() {
  has_payload=0
  for item in "$DIRECTORY"/* "$DIRECTORY"/.[!.]* "$DIRECTORY"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    [ "$item" = "$DIRECTORY/lock" ] || has_payload=1
  done
  [ "$has_payload" = 1 ] || return 0
  if [ -f "$DIRECTORY/rotation_archive_id" ]; then
    old_id=$(read_value "$DIRECTORY/rotation_archive_id")
    valid_id "$old_id" && [ -d "$HISTORY/$old_id/measurement" ] || return 1
  else
    if [ -f "$DIRECTORY/archive_target_id" ]; then
      old_id=$(read_value "$DIRECTORY/archive_target_id")
    else
      old_id=$(current_owner)
      if [ -z "$old_id" ]; then
        new_record
        old_id=${RECORD##*/}
      fi
      valid_id "$old_id" || return 1
      atomic "$DIRECTORY/archive_target_id" "$old_id"
    fi
    valid_id "$old_id" && [ -d "$HISTORY/$old_id" ] && [ ! -L "$HISTORY/$old_id" ] || return 1
    destination=$HISTORY/$old_id/measurement
    [ ! -L "$destination" ] || return 1
    if [ ! -e "$destination" ]; then
      old_phase=$(read_value "$DIRECTORY/phase") || old_phase=unknown
      case $old_phase in complete | failed) ;; *) stop interrupted_previous_session ;; esac
      [ -e "$DIRECTORY/closed_age_s" ] || close_fields "$DIRECTORY"
      copy=$(mktemp -d "$HISTORY/$old_id/.archive.XXXXXX")
      cp -Rp "$DIRECTORY/." "$copy/"
      sync
      mv "$copy" "$destination"
      sync
    else
      case $(read_value "$destination/phase") in complete | failed) ;; *) return 1 ;; esac
    fi
    atomic "$DIRECTORY/rotation_archive_id" "$old_id"
  fi
  set_phase rotating
  for item in "$DIRECTORY"/* "$DIRECTORY"/.[!.]* "$DIRECTORY"/..?*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    case $item in "$DIRECTORY/lock" | "$DIRECTORY/archive_target_id" | "$DIRECTORY/rotation_archive_id") continue ;; esac
    rm -rf "$item"
  done
  sync
  rm -f "$DIRECTORY/archive_target_id" "$DIRECTORY/rotation_archive_id"
  sync
}
prepare_armed() {
  printf '%s\n' "$SCHEMA" >"$DIRECTORY/schema"
  set_phase armed
  printf '%s\n' "$SCHEMA" >"$DIRECTORY/armed"
  sync
}
usage_kib() {
  usage_lines=$(du -sk "$HISTORY" "$DIRECTORY") || return 1
  printf '%s\n' "$usage_lines" | awk '{sum += $1} END {printf "%.0f\n", sum}'
}
prune_history() {
  reserve_records=${1:-0}
  reserve_kib=${2:-0}
  count_limit=$((MAX_HISTORY_RECORDS - reserve_records))
  size_limit=$((MAX_HISTORY_KIB - reserve_kib))
  mkdir -p "$HISTORY" || return 2
  clock_age || return 2
  current_id=$(current_owner) || return 2
  target_id=
  rotation_id=
  admission_id=
  if [ -e "$DIRECTORY/archive_target_id" ]; then
    target_id=$(read_value "$DIRECTORY/archive_target_id") || return 2
    valid_id "$target_id" || return 2
  fi
  if [ -e "$DIRECTORY/rotation_archive_id" ]; then
    rotation_id=$(read_value "$DIRECTORY/rotation_archive_id") || return 2
    valid_id "$rotation_id" || return 2
  fi
  if [ -f "$ADMISSION" ]; then
    load_admission || return 2
    admission_id=$ADMIT_ID
  fi
  count=0
  for entry in "$HISTORY"/session.*; do [ ! -d "$entry" ] || count=$((count + 1)); done
  usage=$(usage_kib) || return 2
  unsigned "$usage" || return 2
  removed=0
  cutoff=$((AGE - RETENTION_DAYS * SECONDS_PER_DAY))
  for entry in "$HISTORY"/session.*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    [ "$removed" -lt "$MAX_PRUNE_BATCH" ] || break
    entry_id=${entry##*/}
    [ "$entry_id" != "$current_id" ] && [ "$entry_id" != "$admission_id" ] && [ "$entry_id" != "$target_id" ] && [ "$entry_id" != "$rotation_id" ] || continue
    expired=0
    if [ "$cutoff" -ge 0 ] && [ -e "$entry/measurement/closed_age_s" ]; then
      closed=$(read_value "$entry/measurement/closed_age_s") || return 2
      unsigned "$closed" || return 2
      [ "$closed" -gt "$cutoff" ] || expired=1
    fi
    if [ "$expired" = 1 ] || [ "$count" -gt "$count_limit" ] || [ "$usage" -gt "$size_limit" ]; then
      rm -rf "$entry" || return 2
      sync || return 2
      removed=$((removed + 1))
      count=$((count - 1))
      usage=$(usage_kib) || return 2
      unsigned "$usage" || return 2
    fi
  done
  [ "$count" -le "$count_limit" ] && [ "$usage" -le "$size_limit" ]
}
admit() {
  resolve_pending_admission
  new_boot=$(read_value "$ROOT/proc/sys/kernel/random/boot_id")
  new_transaction=$(transaction)
  if [ -e "$SKIP" ]; then
    { IFS= read -r skip_boot && IFS= read -r skip_transaction; } <"$SKIP" || return 1
    [ "$skip_boot" != "$new_boot" ] || [ "$skip_transaction" != "$new_transaction" ] || return 1
  fi
  if [ -e "$ADMISSION" ]; then
    load_admission
    if [ "$ADMIT_BOOT" = "$new_boot" ] && [ "$ADMIT_TRANSACTION" = "$new_transaction" ]; then
      fail_admission repeated_start
      return 1
    fi
    fail_admission interrupted_session
  fi
  reserve_records=1
  if [ -z "$(current_owner)" ] && [ ! -e "$DIRECTORY/archive_target_id" ] && [ ! -e "$DIRECTORY/rotation_archive_id" ]; then
    for item in "$DIRECTORY"/* "$DIRECTORY"/.[!.]* "$DIRECTORY"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      [ "$item" = "$DIRECTORY/lock" ] || reserve_records=2
    done
  fi
  current_size=$(du -sk "$DIRECTORY")
  current_size=$(printf '%s\n' "$current_size" | awk '{print $1}')
  unsigned "$current_size" || return 1
  reserve_size=$((current_size + SESSION_RESERVE_KIB + METADATA_RESERVE_KIB))
  prune_result=0
  prune_history "$reserve_records" "$reserve_size" || prune_result=$?
  case $prune_result in 0) ;; 1)
    atomic "$HEALTH" history_capacity
    return 1
    ;;
  *)
    atomic "$HEALTH" retention_io_failure
    return 1
    ;;
  esac
  new_record
  new_id=${RECORD##*/}
  printf '%s\n' "$new_boot" >"$RECORD/boot_id"
  printf '%s\n' "$new_transaction" >"$RECORD/transaction"
  atomic "$ADMISSION" "$new_id" "$new_boot" "$new_transaction"
  ADMIT_ID=$new_id ADMIT_BOOT=$new_boot ADMIT_TRANSACTION=$new_transaction
  archive_current
  printf '%s\n' "$new_id" >"$DIRECTORY/admission_id"
  prepare_armed
}
require_current_transaction() {
  [ ! -e "$DIRECTORY/admission_id" ] || {
    load_admission && [ "$(current_owner)" = "$ADMIT_ID" ] &&
      [ "$(read_value "$ROOT/proc/sys/kernel/random/boot_id")" = "$ADMIT_BOOT" ] && [ "$(transaction)" = "$ADMIT_TRANSACTION" ]
  }
}
bounded_dump() {
  service=$1
  {
    dump_result=0
    timeout -s KILL "$COMMAND_TIMEOUT" dumpsys -t "$COMMAND_TIMEOUT" "$service" 2>"$STAGE/$2.error" || dump_result=$?
    printf '%s\n' "$dump_result" >"$STAGE/$2.exit"
  } | head -c "$((MAX_DUMP_BYTES + 1))" >"$STAGE/$2.txt"
  if [ "$(read_value "$STAGE/$2.exit")" != 0 ]; then printf 'unavailable\n' >"$STAGE/$2_status"; fi
  size=$(wc -c <"$STAGE/$2.txt")
  if [ "$size" -gt "$MAX_DUMP_BYTES" ]; then
    : >"$STAGE/$2.txt"
    printf 'output_limit\n' >"$STAGE/$2_status"
  fi
}
sample() {
  side=$1
  if [ -e "$DIRECTORY/$side" ] || [ -L "$DIRECTORY/$side" ]; then
    stop endpoint_already_exists
    return 1
  fi
  STAGE=$(mktemp -d "$DIRECTORY/.capture.XXXXXX")
  date -u +%Y-%m-%dT%H:%M:%SZ >"$STAGE/utc"
  read_value "$ROOT/proc/sys/kernel/random/boot_id" >"$STAGE/boot_id"
  transaction >"$STAGE/transaction"
  uptime_to "$STAGE/capture_before_s"
  uptime_to "$STAGE/charge_before_s"
  for name in charge_counter charge_full charge_full_design capacity temp voltage_now status; do
    read_value "$ROOT/sys/class/power_supply/battery/$name" >"$STAGE/$name"
  done
  uptime_to "$STAGE/charge_after_s"
  for name in charge_counter charge_full; do
    number=$(read_value "$STAGE/$name")
    case $number in '' | *[!0-9]*)
      stop invalid_gauge
      return 1
      ;;
    esac
  done
  if [ -r "$ROOT/sys/class/power_supply/battery/energy_now" ]; then read_value "$ROOT/sys/class/power_supply/battery/energy_now" >"$STAGE/energy_now"; fi
  if ! pidof android.system.suspend-service >"$STAGE/suspend_pid"; then printf 'unavailable\n' >"$STAGE/suspend_pid"; fi
  uptime_to "$STAGE/suspend_before_s"
  bounded_dump suspend_control_internal suspend
  uptime_to "$STAGE/suspend_after_s"
  uptime_to "$STAGE/rpmh_before_s"
  if [ -r "$ROOT/sys/power/rpmh_stats/master_stats" ]; then
    if ! cp "$ROOT/sys/power/rpmh_stats/master_stats" "$STAGE/rpmh.txt"; then printf 'unavailable\n' >"$STAGE/rpmh_status"; fi
  else printf 'unavailable\n' >"$STAGE/rpmh_status"; fi
  uptime_to "$STAGE/rpmh_after_s"
  bounded_dump power power
  bounded_dump battery battery
  for path in "$ROOT"/sys/power/suspend_stats/*; do
    [ -r "$path" ] || continue
    printf '%s=' "${path##*/}" >>"$STAGE/suspend-stats.txt"
    read_value "$path" >>"$STAGE/suspend-stats.txt"
  done
  if [ -r "$ROOT/proc/interrupts" ]; then cp "$ROOT/proc/interrupts" "$STAGE/interrupts.txt"; fi
  uptime_to "$STAGE/capture_after_s"
  sync
  mv "$STAGE" "$DIRECTORY/$side"
  STAGE=
  sync
}

[ "$(id -u)" = 0 ] || exit 1
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || exit 1
case $1 in arm | start | accept | end | abort | status | monitor-enable | monitor-disable | monitor-status | prune) ;; *) exit 1 ;; esac
case $1 in monitor-enable | monitor-disable | monitor-status | prune) [ "$#" = 1 ] || exit 1 ;; *) ;; esac
umask 077
for path in "$STATE" "$DIRECTORY" "$HISTORY" "$MONITOR" "$ADMISSION" "$CLOCK" "$SEQUENCE" "$HEALTH" "$SKIP"; do [ ! -L "$path" ] || exit 1; done
mkdir -p "$DIRECTORY"
[ ! -L "$DIRECTORY/lock" ] || exit 1
exec 6>"$DIRECTORY/lock"
flock -n 6 || exit 1
ulimit -f "$OUTPUT_LIMIT_BLOCKS"
trap finish EXIT
trap 'exit 1' HUP INT TERM
case $1 in
  arm)
    [ ! -e "$MONITOR" ] || exit 1
    for path in "$DIRECTORY"/* "$DIRECTORY"/.[!.]* "$DIRECTORY"/..?*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      [ "$path" = "$DIRECTORY/lock" ] || {
        printf 'Archive the previous measurement first\n' >&2
        exit 1
      }
    done
    [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || exit 1
    prepare_armed
    ;;
  monitor-enable)
    clock_age
    if [ -e "$SNAPSHOT" ]; then
      atomic "$SKIP" "$(read_value "$ROOT/proc/sys/kernel/random/boot_id")" "$(transaction)"
    else
      rm -f "$SKIP"
      sync
    fi
    atomic "$MONITOR" "$SCHEMA:$RETENTION_DAYS"
    ;;
  monitor-disable)
    rm -f "$MONITOR"
    sync
    ;;
  monitor-status)
    enabled=0
    if [ -e "$MONITOR" ]; then
      monitor_enabled || exit 1
      enabled=1
    fi
    printf 'enabled=%s\nretention_days=%s\n' "$enabled" "$RETENTION_DAYS"
    printf 'retention_clock=observed_monotonic_elapsed_time\nmax_records=%s\nmax_storage_kib=%s\n' "$MAX_HISTORY_RECORDS" "$MAX_HISTORY_KIB"
    if [ -e "$HEALTH" ]; then
      printf 'error='
      read_value "$HEALTH"
    else printf 'error=none\n'; fi
    ;;
  status) if [ -e "$DIRECTORY/phase" ]; then read_value "$DIRECTORY/phase"; else printf 'unarmed\n'; fi ;;
  prune)
    prune_history
    rm -f "$HEALTH"
    sync
    ;;
  start)
    if [ -e "$MONITOR" ]; then
      monitor_enabled
      admit
    fi
    [ -e "$DIRECTORY/armed" ] || exit 0
    [ "$(read_value "$DIRECTORY/phase")" = armed ] || {
      stop repeated_or_interrupted_start
      exit 1
    }
    require_current_transaction
    set_phase capturing_start
    sample start
    set_phase prepared
    ;;
  accept)
    [ -e "$DIRECTORY/armed" ] || exit 0
    require_current_transaction
    [ "$(read_value "$DIRECTORY/phase")" = prepared ] || {
      stop missing_start
      exit 1
    }
    uptime_to "$DIRECTORY/accepted_s"
    set_phase sleeping
    ;;
  end)
    [ -e "$DIRECTORY/armed" ] || exit 0
    [ "$#" = 2 ] || exit 1
    require_current_transaction
    [ "$(read_value "$DIRECTORY/phase")" = sleeping ] || {
      stop uncommitted_start
      exit 1
    }
    [ "$2" = guard ] || {
      stop "$2"
      exit 0
    }
    set_phase capturing_end
    sample end
    [ "$(read_value "$DIRECTORY/start/boot_id")" = "$(read_value "$DIRECTORY/end/boot_id")" ] || {
      stop rebooted
      exit 1
    }
    [ "$(read_value "$DIRECTORY/start/transaction")" = "$(read_value "$DIRECTORY/end/transaction")" ] || {
      stop policy_transaction_changed
      exit 1
    }
    printf '%s\n' "$2" >"$DIRECTORY/reason"
    close_fields "$DIRECTORY"
    set_phase complete
    rm "$DIRECTORY/armed"
    sync
    if [ -e "$MONITOR" ]; then
      monitor_enabled
      prune_history
    fi
    rm -f "$HEALTH"
    sync
    ;;
  abort)
    resolve_pending_admission
    if [ -e "$ADMISSION" ]; then
      load_admission
      fail_admission "${2:-interrupted}"
    fi
    [ -e "$DIRECTORY/armed" ] || exit 0
    stop "${2:-interrupted}"
    ;;
  *) exit 1 ;;
esac
