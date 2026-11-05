#!/system/bin/sh
set -eu
ROOT_SHELL=/data/adb/magisk/busybox
if [ -x "$ROOT_SHELL" ] && [ "$(readlink /proc/$$/exe)" != "$(readlink -f "$ROOT_SHELL")" ]; then
  exec "$ROOT_SHELL" sh "$0" "$@"
fi
PATH=${POWER_MODE_COMMAND_PATH:-/product/bin:/system_ext/bin:/system/bin:/system/xbin}
export PATH
ROOT=${POWER_MODE_DEVICE_ROOT:-}
PACKAGE=local.power.mode
CONTROL=$ROOT/data/adb/power-mode-control
RECOVERY=$ROOT/data/adb/service.d/90-power-mode-recover.sh
READING=$ROOT/data/adb/reading-mode-control
STATE=$ROOT/data/adb/power-mode
SHARED_LOCK=$ROOT/data/adb/power-mode-settings.lock
READING_STATE=$ROOT/data/adb/reading-mode
PRIVATE=$ROOT/data/user_de/0/$PACKAGE/files
MAINTENANCE=$PRIVATE/maintenance
INSTALL_TIMEOUT=120
START_POLLS=20
POLL_DELAY=1
mutated=0
committed=0
shared_locked=0
reading_locked=0
policy_changed=0
backup=
uid=
prior_mode=

fail() {
  printf '%s\n' "$*" >&2
  return 1
}
release_locks() {
  if [ "$shared_locked" = 1 ]; then
    flock -u 7 || return 1
    shared_locked=0
  fi
  if [ "$reading_locked" = 1 ]; then
    flock -u 5 || return 1
    reading_locked=0
  fi
}
policy_row() {
  magisk --sqlite "SELECT uid,policy,until,logging,notification FROM policies WHERE uid=$uid;"
}
restore_policy() {
  [ "$policy_changed" = 1 ] || return 0
  current=$(policy_row) || return 1
  prior=$(cat "$backup/policy") || return 1
  if [ "$current" != "$prior" ] && [ "$current" != "uid=$uid|policy=2|until=0|logging=1|notification=0" ]; then
    fail 'Magisk policy changed externally; refusing to overwrite it'
    return 1
  fi
  query="DELETE FROM policies WHERE uid=$uid;"
  if [ -s "$backup/policy" ]; then
    values=$(awk -F '[=|]' -v uid="$uid" '
      NF == 10 && $1 == "uid" && $2 == uid && $3 == "policy" && $5 == "until" && $7 == "logging" && $9 == "notification" {
        for (i=2; i<=10; i+=2) if ($i !~ /^-?[0-9]+$/) exit 1
        print $2 "," $4 "," $6 "," $8 "," $10; found=1
      }
      END {if (!found) exit 1}
    ' "$backup/policy") || return 1
    query="$query INSERT INTO policies(uid,policy,until,logging,notification) VALUES($values);"
  fi
  magisk --sqlite "BEGIN IMMEDIATE; $query COMMIT;" || return 1
  [ "$(policy_row)" = "$prior" ]
}
restore_file() {
  name=$1 path=$2
  if [ -e "$backup/$name" ]; then
    cp -p "$backup/$name" "$path.rollback" && mv "$path.rollback" "$path" && restorecon "$path"
  else rm -f "$path"; fi
}
rollback() {
  release_locks || return 1
  touch "$MAINTENANCE" || return 1
  am force-stop --user 0 "$PACKAGE" || return 1
  if [ -x "$CONTROL" ]; then
    [ "$(timeout "$INSTALL_TIMEOUT" "$CONTROL" disable)" = off ] || return 1
  fi
  [ ! -e "$STATE/snapshot" ] && [ ! -L "$STATE/snapshot" ] || return 1
  restore_file controller "$CONTROL" || return 1
  restore_file recovery "$RECOVERY" || return 1
  restore_file reading "$READING" || return 1
  [ "$(timeout "$INSTALL_TIMEOUT" pm install -r -g -d "$backup/app.apk")" = Success ] || return 1
  am force-stop --user 0 "$PACKAGE" || return 1
  restore_policy || return 1
  if [ -e "$backup/enabled" ]; then
    cp -p "$backup/enabled" "$STATE/enabled" || return 1
  else rm -f "$STATE/enabled" || return 1; fi
  sync || return 1
  case $prior_mode in
    armed | sleeping)
      am start-foreground-service --user 0 -n "$PACKAGE/.StandbyService" -a "$PACKAGE.RECONCILE" --ez allow_maintenance true >/dev/null || return 1
      attempt=0
      restored=stopped
      while [ "$attempt" -lt "$START_POLLS" ]; do
        if ! restored=$("$CONTROL" status); then restored=stopped; fi
        case $restored in armed | sleeping) break ;; stopped) ;; *) return 1 ;; esac
        sleep "$POLL_DELAY"
        attempt=$((attempt + 1))
      done
      case $restored in armed | sleeping) ;; *) return 1 ;; esac
      ;;
    off | stopped) ;;
    *) return 1 ;;
  esac
  rm "$MAINTENANCE" || return 1
}
finish() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$mutated" = 1 ] && [ "$committed" = 0 ]; then
    if rollback; then
      printf 'rollback=complete\nbackup=%s\n' "$backup" >&2
    else
      touch "$MAINTENANCE" || true
      am force-stop --user 0 "$PACKAGE" || true
      if [ -x "$CONTROL" ]; then timeout "$INSTALL_TIMEOUT" "$CONTROL" disable >/dev/null || true; fi
      printf 'Rollback incomplete; keep the helper stopped and retain backup=%s\n' "$backup" >&2
    fi
    result=1
  fi
  release_locks || result=1
  exit "$result"
}

[ "$(id -u)" = 0 ] && [ "$(getprop ro.product.device)" = pipa ] || exit 1
[ "$#" = 1 ] || exit 1
stage=$1
for file in controller recover reading app.apk; do [ -f "$stage/$file" ] || exit 1; done
[ "$(cmd activity get-current-user)" = 0 ] || {
  fail 'Install from the owner user'
  exit 1
}
[ ! -e "$MAINTENANCE" ] || {
  fail 'An unfinished installation requires recovery'
  exit 1
}
[ ! -e "$READING_STATE/snapshot" ] || {
  fail 'Restore Reading Mode first'
  exit 1
}
[ ! -e "$ROOT/data/adb/service.d/99-pad6-idle-saver.sh" ] || {
  fail 'Retire the legacy idle-saver first'
  exit 1
}
for executable in timeout flock magisk pm am cmd restorecon; do command -v "$executable" >/dev/null; done
sh -n "$stage/controller"
sh -n "$stage/recover"
sh -n "$stage/reading"
chmod 0700 "$stage/controller"
[ "$(POWER_MODE_STATE_DIR="$stage/check" "$stage/controller" check)" = ready ]
uid=$(cmd package list packages -U --user 0 "$PACKAGE" | awk -v package="package:$PACKAGE" '$1 == package {sub(/^uid:/,"",$2); print $2}')
case $uid in '' | *[!0-9]*) exit 1 ;; esac
[ "$uid" -ge 10000 ] && [ "$uid" -lt 20000 ]
[ "$(cmd package list packages -U --user 0 --uid "$uid")" = "package:$PACKAGE uid:$uid" ]
apk=$(pm path --user 0 "$PACKAGE")
case $apk in package:*) apk=${apk#package:} ;; *) exit 1 ;; esac
[ -f "$apk" ]
umask 077
mkdir -p "$STATE" "$READING_STATE" "$ROOT/data/adb/service.d" "$ROOT/data/adb/power-mode-backups"
exec 6>"$STATE/install.lock"
flock -n 6 || {
  fail 'Another installation is running'
  exit 1
}
backup=$(mktemp -d "$ROOT/data/adb/power-mode-backups/standby.XXXXXX")
cp -p "$apk" "$backup/app.apk"
for entry in "controller:$CONTROL" "recovery:$RECOVERY" "reading:$READING" "enabled:$STATE/enabled"; do
  name=${entry%%:*} path=${entry#*:}
  [ ! -e "$path" ] || cp -p "$path" "$backup/$name"
done
policy_row >"$backup/policy"
if [ -x "$CONTROL" ]; then prior_mode=$("$CONTROL" status); else prior_mode=off; fi
case $prior_mode in off | stopped | armed | sleeping) ;; *)
  fail 'Recover the existing controller first'
  exit 1
  ;;
esac
printf '%s\n' "$prior_mode" >"$backup/prior-mode"
sync
trap finish EXIT
trap 'exit 1' HUP INT TERM
mutated=1
mkdir -p "$PRIVATE"
chown "$uid:$uid" "$PRIVATE"
chmod 0700 "$PRIVATE"
touch "$MAINTENANCE"
chown "$uid:$uid" "$MAINTENANCE"
restorecon -RF "$PRIVATE"
am force-stop --user 0 "$PACKAGE"
if [ -x "$CONTROL" ]; then [ "$(timeout "$INSTALL_TIMEOUT" "$CONTROL" disable)" = off ]; fi
[ ! -e "$STATE/snapshot" ] && [ ! -L "$STATE/snapshot" ]
exec 8>"$STATE/controller.lock"
flock -n 8
flock -u 8
exec 5>"$READING_STATE/lock"
flock -n 5
reading_locked=1
exec 7>"$SHARED_LOCK"
flock -n 7
shared_locked=1
[ ! -e "$READING_STATE/snapshot" ]
[ "$(timeout "$INSTALL_TIMEOUT" pm install -r -g "$stage/app.apk")" = Success ]
for entry in "controller:$CONTROL" "recover:$RECOVERY" "reading:$READING"; do
  name=${entry%%:*} path=${entry#*:}
  cp "$stage/$name" "$path.new"
  chmod 0700 "$path.new"
  chown 0:0 "$path.new"
  sync
  mv "$path.new" "$path"
  restorecon "$path"
done
release_locks
am force-stop --user 0 "$PACKAGE"
policy_changed=1
magisk --sqlite "INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) VALUES($uid,2,0,1,0);"
[ "$(policy_row)" = "uid=$uid|policy=2|until=0|logging=1|notification=0" ]
[ "$("$CONTROL" enable)" = stopped ]
sync
am start-foreground-service --user 0 -n "$PACKAGE/.StandbyService" -a "$PACKAGE.RECONCILE" --ez allow_maintenance true >/dev/null
poll=0
mode=stopped
while [ "$poll" -lt "$START_POLLS" ]; do
  if ! mode=$("$CONTROL" status); then mode=stopped; fi
  case $mode in armed | sleeping) break ;; stopped) ;; *)
    fail "Unexpected controller state: $mode"
    exit 1
    ;;
  esac
  sleep "$POLL_DELAY"
  poll=$((poll + 1))
done
case $mode in armed | sleeping) ;; *)
  fail 'Headless helper did not arm'
  exit 1
  ;;
esac
rm "$MAINTENANCE"
sync
printf 'complete\n' >"$backup/phase"
sync
committed=1
printf 'mode=%s\nbackup=%s\n' "$mode" "$backup"
