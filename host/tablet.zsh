tablet() {
  local project_root="${XIAOMI_PROJECTS_ROOT:-$HOME/xiaomi-pad-projects}"
  local dispatcher=/data/data/com.termux/files/home/bin/tablet-playback
  if [[ ${1:-} == sync ]]; then
    shift
    "$project_root/android/install-tablet-stack.sh" --apps "$@"
    return
  fi
  (( $# )) || set -- help
  print -rl -- "$@" | ssh "${XIAOMI_SSH_HOST:-xiaomi}" "su -c $dispatcher"
}
