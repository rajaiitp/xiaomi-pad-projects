#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project="$script_dir/apps/power-mode"
tools=${QUALITY_TOOLS:-${READING_MODE_TOOLS:-"$HOME/.cache/reading-mode-tools"}}
toolchain="$HOME/.local/share/network-reticulum/toolchains"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$toolchain/android-sdk"}}
java_home=${JAVA_HOME_21:-${JAVA_HOME:-"$toolchain/jdk"}}
shfmt=${SHFMT:-"$tools/shfmt"}
shellcheck=${SHELLCHECK:-"$tools/shellcheck"}
ruff=${RUFF:-"$tools/ruff"}
java_formatter=${JAVA_FORMAT_JAR:-"$tools/google-java-format-1.28.0-all-deps.jar"}
scripts=("$script_dir"/{build,check,format,install,probe}-power-mode.sh)
"$shfmt" -d -i 2 -ci "$script_dir"/power-mode/*.sh "${scripts[@]}"
"$shellcheck" -s sh "$script_dir"/power-mode/*.sh
"$shellcheck" "${scripts[@]}"
"$ruff" format --check "$script_dir/tests/test_power_mode.py" "$script_dir/tests/test_charge_limit.py" "$script_dir/tests/test_power_mode_install.py"
"$ruff" check "$script_dir/tests/test_power_mode.py" "$script_dir/tests/test_charge_limit.py" "$script_dir/tests/test_power_mode_install.py"
mapfile -t sources < <(find "$project/src" "$project/tests/java" "$project/probe" -name '*.java' -type f | sort)
"$java_home/bin/java" -jar "$java_formatter" --aosp --dry-run --set-exit-if-changed "${sources[@]}"
for pattern in test_power_mode.py test_charge_limit.py test_power_mode_install.py; do
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$script_dir/tests" -p "$pattern" -v
done
test_output="$script_dir/power-mode/build/tests"
mkdir -p "$test_output" "$test_output/probe"
"$java_home/bin/javac" -source 8 -target 8 -Xlint:all -Werror \
  -bootclasspath "$sdk/platforms/android-37.0/android.jar" -d "$test_output/probe" \
  "$project/probe/local/power/mode/research/FrameworkProbe.java"
"$java_home/bin/javac" --release 8 -Xlint:all -Werror -d "$test_output" \
  "$project/src/local/power/mode/RootChannel.java" "$project/tests/java/local/power/mode/RootChannelTest.java"
"$java_home/bin/java" -cp "$test_output" local.power.mode.RootChannelTest
JAVA_HOME="$java_home" ANDROID_HOME="$sdk" bash "$script_dir/build-power-mode.sh"
JAVA_HOME="$java_home" ANDROID_HOME="$sdk" "$sdk/cmdline-tools/latest/bin/lint" \
  -Werror --exitcode --compile-sdk-version 37.0 --classpath "$project/build/classes" "$project"
