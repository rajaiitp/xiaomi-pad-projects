#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project=${1:-"$script_dir/apps/tv-touch-controller"}
out=${2:-"$project/build"}
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/Android/Sdk"}}
tools="$sdk/build-tools/36.0.0"
platform="$sdk/platforms/android-36/android.jar"
java_home=${JAVA_HOME_21:-${JAVA_HOME:?Set JAVA_HOME or JAVA_HOME_21}}
properties=${TV_TOUCH_SIGNING_PROPERTIES:-"$HOME/.android/tv-touch-controller.properties"}

rm -rf "$out"
mkdir -p "$out/compiled" "$out/gen" "$out/classes" "$out/dex"

if [[ ! -f $properties ]]; then
  mkdir -p "$(dirname "$properties")"
  password=$(openssl rand -hex 24)
  keystore="${properties%.properties}.jks"
  [[ ! -e $keystore ]] || {
    printf 'Keystore exists without signing properties\n' >&2
    exit 1
  }
  "$java_home/bin/keytool" -genkeypair -noprompt \
    -keystore "$keystore" -storepass "$password" -keypass "$password" \
    -alias tv-touch-controller -keyalg RSA -keysize 4096 -validity 10000 \
    -dname "CN=TV Touch Controller, OU=Local Android, O=Raja, C=DE"
  cat >"$properties" <<EOF
storeFile=$keystore
alias=tv-touch-controller
storePassword=$password
keyPassword=$password
EOF
  chmod 600 "$properties" "$keystore"
fi

while IFS='=' read -r key value; do
  case $key in
    storeFile) store_file=$value ;;
    alias) key_alias=$value ;;
    storePassword) store_password=$value ;;
    keyPassword) key_password=$value ;;
  esac
done <"$properties"

"$tools/aapt2" compile --dir "$project/res" -o "$out/compiled/resources.zip"
"$tools/aapt2" link -I "$platform" --manifest "$project/AndroidManifest.xml" \
  --java "$out/gen" --min-sdk-version 26 --target-sdk-version 36 \
  --version-code 10 --version-name 1.9 -o "$out/unsigned.apk" \
  "$out/compiled/resources.zip"
mapfile -t sources < <(find "$project/src" "$out/gen" -name '*.java' -type f | sort)
"$java_home/bin/javac" -source 8 -target 8 -bootclasspath "$platform:$tools/core-lambda-stubs.jar" \
  -d "$out/classes" "${sources[@]}"
"$java_home/bin/jar" cf "$out/classes.jar" -C "$out/classes" .
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" \
  "$tools/d8" --lib "$platform" --min-api 26 --output "$out/dex" "$out/classes.jar"
zip -q -j "$out/unsigned.apk" "$out/dex/classes.dex"
"$tools/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" "$tools/apksigner" sign \
  --ks "$store_file" --ks-key-alias "$key_alias" \
  --ks-pass "pass:$store_password" --key-pass "pass:$key_password" \
  --out "$out/tv-touch-controller.apk" "$out/aligned.apk"
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" \
  "$tools/apksigner" verify --verbose "$out/tv-touch-controller.apk"
printf '%s\n' "$out/tv-touch-controller.apk"
