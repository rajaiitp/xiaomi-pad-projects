#!/usr/bin/env bash
set -euo pipefail
umask 077
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project="$script_dir/apps/power-mode"
out="$project/build"
toolchain="$HOME/.local/share/network-reticulum/toolchains"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$toolchain/android-sdk"}}
java_home=${JAVA_HOME_21:-${JAVA_HOME:-"$toolchain/jdk"}}
tools="$sdk/build-tools/36.0.0"
platform="$sdk/platforms/android-37.0/android.jar"
properties="$HOME/.android/power-mode.properties"

for executable in "$tools/aapt2" "$tools/d8" "$tools/zipalign" "$tools/apksigner" \
  "$java_home/bin/javac" "$java_home/bin/keytool"; do
  [[ -x $executable ]] || {
    printf 'Missing build tool: %s\n' "$executable" >&2
    exit 1
  }
done
[[ -f $platform ]] || {
  printf 'Missing Android SDK platform\n' >&2
  exit 1
}
if [[ ! -f $properties ]]; then
  mkdir -p "$(dirname -- "$properties")"
  keystore="$HOME/.android/power-mode.jks"
  [[ ! -e $keystore ]] || {
    printf 'Signing properties missing for existing keystore\n' >&2
    exit 1
  }
  POWER_MODE_PASSWORD=$(openssl rand -hex 24)
  export POWER_MODE_PASSWORD
  "$java_home/bin/keytool" -genkeypair -noprompt -keystore "$keystore" \
    -storepass:env POWER_MODE_PASSWORD -keypass:env POWER_MODE_PASSWORD \
    -alias power-mode -keyalg RSA -keysize 4096 -validity 10000 -dname 'CN=Offline Standby'
  temporary=$(mktemp "$properties.XXXXXX")
  printf 'storeFile=%s\nalias=power-mode\nstorePassword=%s\nkeyPassword=%s\n' \
    "$keystore" "$POWER_MODE_PASSWORD" "$POWER_MODE_PASSWORD" >"$temporary"
  chmod 600 "$temporary" "$keystore"
  mv "$temporary" "$properties"
  unset POWER_MODE_PASSWORD
fi
store_file='' key_alias='' store_password='' key_password=''
while IFS='=' read -r key value; do
  case $key in
    storeFile) store_file=$value ;;
    alias) key_alias=$value ;;
    storePassword) store_password=$value ;;
    keyPassword) key_password=$value ;;
    *)
      printf 'Unknown signing property\n' >&2
      exit 1
      ;;
  esac
done <"$properties"
[[ -f $store_file && -n $key_alias && -n $store_password && -n $key_password ]] || exit 1
rm -rf "$out"
mkdir -p "$out/compiled" "$out/gen" "$out/classes" "$out/dex"
"$tools/aapt2" compile --dir "$project/res" -o "$out/compiled/resources.zip"
"$tools/aapt2" link -I "$platform" --manifest "$project/AndroidManifest.xml" \
  --java "$out/gen" --min-sdk-version 28 --target-sdk-version 37 \
  --version-code 2 --version-name 2.0 -o "$out/unsigned.apk" "$out/compiled/resources.zip"
mapfile -t sources < <(find "$project/src" "$out/gen" -name '*.java' -type f | sort)
"$java_home/bin/javac" -source 8 -target 8 -Xlint:all -Werror \
  -bootclasspath "$platform:$tools/core-lambda-stubs.jar" -d "$out/classes" "${sources[@]}"
"$java_home/bin/jar" cf "$out/classes.jar" -C "$out/classes" .
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" \
  "$tools/d8" --lib "$platform" --min-api 28 --output "$out/dex" "$out/classes.jar"
zip -q -j "$out/unsigned.apk" "$out/dex/classes.dex"
"$tools/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
export POWER_MODE_STORE_PASSWORD="$store_password" POWER_MODE_KEY_PASSWORD="$key_password"
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" "$tools/apksigner" sign \
  --ks "$store_file" --ks-key-alias "$key_alias" \
  --ks-pass env:POWER_MODE_STORE_PASSWORD --key-pass env:POWER_MODE_KEY_PASSWORD \
  --out "$out/power-mode.apk" "$out/aligned.apk"
unset POWER_MODE_STORE_PASSWORD POWER_MODE_KEY_PASSWORD
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" "$tools/apksigner" verify "$out/power-mode.apk"
printf '%s\n' "$out/power-mode.apk"
