#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project="$script_dir/apps/reading-mode"
toolchain="$HOME/.local/share/network-reticulum/toolchains"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$toolchain/android-sdk"}}
java_home=${JAVA_HOME_21:-${JAVA_HOME:-"$toolchain/jdk"}}
quality_tools=${READING_MODE_TOOLS:-"$HOME/.cache/reading-mode-tools"}
shfmt=${SHFMT:-"$quality_tools/shfmt"}
shellcheck=${SHELLCHECK:-"$quality_tools/shellcheck"}
ruff=${RUFF:-"$quality_tools/ruff"}
java_formatter=${JAVA_FORMAT_JAR:-"$quality_tools/google-java-format-1.28.0-all-deps.jar"}

for executable in "$shfmt" "$shellcheck" "$ruff" "$java_home/bin/java" \
  "$sdk/cmdline-tools/latest/bin/lint"; do
  [[ -x $executable ]] || {
    printf 'Missing check tool: %s\n' "$executable" >&2
    exit 1
  }
done
[[ -f $java_formatter ]] || {
  printf 'Missing Google Java Format 1.28.0: %s\n' "$java_formatter" >&2
  exit 1
}
scripts=("$script_dir/build-reading-mode.sh" "$script_dir/install-reading-mode.sh" "$script_dir/check-reading-mode.sh")
"$shfmt" -d -i 2 -ci "$script_dir/reading-mode.sh" "${scripts[@]}"
"$shellcheck" -s sh "$script_dir/reading-mode.sh"
"$shellcheck" "${scripts[@]}"
"$ruff" format --check "$script_dir/tests/test_reading_mode.py"
"$ruff" check "$script_dir/tests/test_reading_mode.py"
mapfile -t java_sources < <(find "$project/src" -name '*.java' -type f | sort)
"$java_home/bin/java" -jar "$java_formatter" --aosp --dry-run --set-exit-if-changed "${java_sources[@]}"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$script_dir/tests" -p 'test_reading_mode.py' -v
JAVA_HOME="$java_home" ANDROID_HOME="$sdk" "$script_dir/build-reading-mode.sh"
JAVA_HOME="$java_home" ANDROID_HOME="$sdk" "$sdk/cmdline-tools/latest/bin/lint" \
  -Werror --exitcode --compile-sdk-version 37.0 --classpath "$project/build/classes" "$project"
