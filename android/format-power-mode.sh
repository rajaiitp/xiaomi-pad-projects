#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project="$script_dir/apps/power-mode"
tools=${QUALITY_TOOLS:-${READING_MODE_TOOLS:-"$HOME/.cache/reading-mode-tools"}}
java_home=${JAVA_HOME_21:-${JAVA_HOME:-"$HOME/.local/share/network-reticulum/toolchains/jdk"}}
shfmt=${SHFMT:-"$tools/shfmt"}
ruff=${RUFF:-"$tools/ruff"}
java_formatter=${JAVA_FORMAT_JAR:-"$tools/google-java-format-1.28.0-all-deps.jar"}
"$shfmt" -w -i 2 -ci "$script_dir"/power-mode/*.sh "$script_dir"/{build,check,format,install,probe}-power-mode.sh
"$ruff" format "$script_dir/tests/test_power_mode.py" "$script_dir/tests/test_charge_limit.py" "$script_dir/tests/test_power_mode_install.py" "$script_dir/tests/test_standby_measurement.py" "$script_dir/power-mode/analyze.py"
mapfile -t sources < <(find "$project/src" "$project/tests/java" "$project/probe" -name '*.java' -type f | sort)
"$java_home/bin/java" -jar "$java_formatter" --aosp --replace "${sources[@]}"
