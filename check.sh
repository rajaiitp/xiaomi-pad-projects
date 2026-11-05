#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SHFMT=$(command -v "${SHFMT:-shfmt}")
SHELLCHECK=$(command -v "${SHELLCHECK:-shellcheck}")
RUFF=$(command -v "${RUFF:-ruff}")
export SHFMT SHELLCHECK RUFF
: "${JAVA_HOME:?Set JAVA_HOME}"
: "${JAVA_FORMAT_JAR:?Set JAVA_FORMAT_JAR to Google Java Format 1.28.0}"

mapfile -d '' shell_sources < <(find "$root/android" "$root/display" -type f \
  \( -name '*.sh' -o -path '*/legacy-notification/*' -o -path '*/termux-boot/*' \) \
  -not -path '*/build/*' -print0)
"$SHFMT" -d -i 2 -ci "$root/check.sh" "${shell_sources[@]}"
"$SHELLCHECK" "$root/check.sh" "${shell_sources[@]}"
zsh -n "$root/host/tablet.zsh"
"$RUFF" format --check "$root/books" "$root/android/tests"
"$RUFF" check "$root/books" "$root/android/tests"
mapfile -d '' java_sources < <(find "$root/android/apps" -type f -name '*.java' -not -path '*/build/*' -print0)
"$JAVA_HOME/bin/java" -jar "$JAVA_FORMAT_JAR" --aosp --dry-run --set-exit-if-changed "${java_sources[@]}"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$root/books/tests" -v
"$root/android/check-reading-mode.sh"
"$root/android/check-power-mode.sh"
