#!/system/bin/sh
# Magisk service for the Xiaomi Pad 6 (pipa).
# Enable Android Battery Saver and force deep Doze after five minutes without
# user interaction, but never while charging or when an HDMI/external display
# is active. This script is intentionally Android/toybox-sh compatible.

PATH=/system/bin:/system/xbin:/product/bin
export PATH

SERVICE_NAME="pad6-idle-saver"
BASE_DIR="/data/adb/${SERVICE_NAME}"
ACTIVE_FILE="${BASE_DIR}/active"
MANAGED_SAVER_FILE="${BASE_DIR}/managed-battery-saver"
PID_FILE="${BASE_DIR}/pid"
LOG_FILE="${BASE_DIR}/service.log"
IDLE_THRESHOLD_MS=300000
POLL_SECONDS=10

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"${LOG_FILE}"
}

is_charging() {
  dumpsys battery 2>/dev/null | grep -qE '^(  )?(AC powered|USB powered|Wireless powered): true$'
}

is_hdmi_active() {
  # Android exposes wired HDMI/DisplayPort output as an EXTERNAL display. The
  # DisplayDeviceInfo record is a single line; field order varies by Android
  # build, so check the type and state independently on each record.
  dumpsys display 2>/dev/null | awk '
    /DisplayDeviceInfo/ {
      external = ($0 ~ /HDMI/ || $0 ~ /type (EXTERNAL|HDMI)/)
      active = ($0 ~ /state (ON|DOZE)/)
      if (external && active) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

is_ssh_active() {
  # Count a live remote SSH shell/session, not merely the Termux sshd listener.
  ss -Htnp state established 2>/dev/null | grep -Eq 'users:.*"(sshd|dropbear)"'
}

is_adb_active() {
  # The ADB manager exposes actual host connectivity, unlike the broader USB
  # cable state which can be true for a charger or HDMI adapter alone.
  dumpsys adb 2>/dev/null | grep -q 'connected_to_adb=true'
}

last_user_activity_ms() {
  dumpsys power 2>/dev/null |
    sed -n 's/.*mLastUserActivityTime(excludingAttention)=\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

uptime_ms() {
  awk '{ print int($1 * 1000) }' /proc/uptime
}

battery_saver_enabled() {
  [ "$(settings get global low_power 2>/dev/null)" = "1" ]
}

leave_extreme_mode() {
  [ -e "${ACTIVE_FILE}" ] || return 0

  cmd deviceidle unforce >/dev/null 2>&1 || true
  if [ -r "${MANAGED_SAVER_FILE}" ] && [ "$(cat "${MANAGED_SAVER_FILE}")" = "1" ]; then
    cmd power set-mode 0 >/dev/null 2>&1 || settings put global low_power 0 >/dev/null 2>&1 || true
  fi
  rm -f "${ACTIVE_FILE}" "${MANAGED_SAVER_FILE}"
  log "left extreme mode"
}

enter_extreme_mode() {
  if [ ! -e "${ACTIVE_FILE}" ]; then
    if battery_saver_enabled; then
      printf '0\n' >"${MANAGED_SAVER_FILE}"
    else
      if cmd power set-mode 1 >/dev/null 2>&1 || settings put global low_power 1 >/dev/null 2>&1; then
        printf '1\n' >"${MANAGED_SAVER_FILE}"
      else
        log "could not enable Battery Saver"
        return 1
      fi
    fi
    : >"${ACTIVE_FILE}"
    log "entered extreme mode after ${IDLE_THRESHOLD_MS} ms of inactivity"
  fi

  # Reassert this after a boot or a system-initiated Doze exit while the
  # conditions are still idle. It is harmless when already forced.
  cmd deviceidle force-idle >/dev/null 2>&1 || log "could not force deep Doze"
}

status() {
  now="$(uptime_ms)"
  last="$(last_user_activity_ms)"
  if [ -z "${last}" ] || [ -z "${now}" ]; then
    idle="unknown"
  else
    idle="$((now - last))"
  fi

  printf 'service=%s\n' "${SERVICE_NAME}"
  printf 'idle_ms=%s\n' "${idle}"
  printf 'charging=%s\n' "$(is_charging && echo true || echo false)"
  printf 'hdmi_active=%s\n' "$(is_hdmi_active && echo true || echo false)"
  printf 'ssh_active=%s\n' "$(is_ssh_active && echo true || echo false)"
  printf 'adb_active=%s\n' "$(is_adb_active && echo true || echo false)"
  printf 'battery_saver=%s\n' "$(battery_saver_enabled && echo true || echo false)"
  printf 'extreme_mode=%s\n' "$(test -e "${ACTIVE_FILE}" && echo true || echo false)"
}

tick() {
  now="$(uptime_ms)"
  last="$(last_user_activity_ms)"

  # Treat an unreadable power state as active: fail safe rather than forcing
  # Doze while the system service is not ready.
  if [ -z "${now}" ] || [ -z "${last}" ]; then
    leave_extreme_mode
    return
  fi

  idle_ms="$((now - last))"
  if is_charging || is_hdmi_active || is_ssh_active || is_adb_active || [ "${idle_ms}" -lt "${IDLE_THRESHOLD_MS}" ]; then
    leave_extreme_mode
  else
    enter_extreme_mode
  fi
}

start_daemon() {
  mkdir -p "${BASE_DIR}"
  chmod 700 "${BASE_DIR}"

  if [ -r "${PID_FILE}" ]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null)"
    if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
      exit 0
    fi
  fi
  printf '%s\n' "$$" >"${PID_FILE}"
  rm -f "${ACTIVE_FILE}" "${MANAGED_SAVER_FILE}"
  cleanup() {
    trap - INT TERM EXIT
    leave_extreme_mode
    rm -f "${PID_FILE}"
    exit 0
  }
  trap cleanup INT TERM EXIT

  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
  log "service started"
  while true; do
    tick
    sleep "${POLL_SECONDS}"
  done
}

case "${1:-}" in
  --status)
    status
    ;;
  --once)
    mkdir -p "${BASE_DIR}"
    tick
    status
    ;;
  "")
    start_daemon
    ;;
  *)
    echo "usage: $0 [--status|--once]" >&2
    exit 2
    ;;
esac
