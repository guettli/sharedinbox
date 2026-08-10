#!/usr/bin/env bash
# Local reproducer for the Play Store launch-crash check that CI performs in
# Firebase Test Lab. Fetches the alpha APK set, installs it onto a connected
# Android emulator, launches the main activity and watches the crash logcat
# for FATAL EXCEPTION lines for ~15 s. Exits non-zero on a crash signal.
#
# Run inside nix develop (needs adb + Android SDK + a service-account key in
# PLAY_STORE_CONFIG_JSON):
#   scripts/playstore_launch_check_local.sh
#
# This mirrors what CI does — see scripts/run_firebase_test.sh and
# ci/main.go TestAndroidFirebase.
set -Eeuo pipefail
[ "$(id -u)" != "0" ] || { echo "ERROR: Do not run as root. See DEVELOPMENT.md."; exit 1; }

if [ -z "${PLAY_STORE_CONFIG_JSON:-}" ]; then
    echo "ERROR: PLAY_STORE_CONFIG_JSON not set — needed to fetch the alpha APK."
    echo "       Source secrets.enc.yaml via sops, or export it manually."
    exit 1
fi

if [ -z "${ANDROID_HOME:-}" ]; then
    echo "ERROR: ANDROID_HOME is not set. Add it to your ~/.zshrc or ~/.bashrc:" >&2
    echo "  export ANDROID_HOME=\"\$HOME/Android/Sdk\"" >&2
    exit 1
fi

PACKAGE="de.sharedinbox.mua"
APK_DIR=$(mktemp -d /tmp/playstore-apks-XXXXXX)
trap 'rm -rf "$APK_DIR"' EXIT

echo "Fetching latest alpha APK set to $APK_DIR…"
VERSION_CODE=$(python3 scripts/fetch_playstore_apks.py "$APK_DIR")
echo "Got versionCode=$VERSION_CODE"

ADB=$(command -v adb 2>/dev/null || echo "$ANDROID_HOME/platform-tools/adb")
"$ADB" version >/dev/null 2>&1 || {
    echo "adb not found at $ADB — install platform-tools under \$ANDROID_HOME or add it to PATH"
    exit 1
}

# AVD boot logic mirrors stalwart-dev/run_android.sh; if no emulator is up we
# boot sharedinbox_test in the background.
EMULATOR_ID=$("$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
if [ -z "$EMULATOR_ID" ]; then
    if [ ! -c /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "ERROR: KVM (/dev/kvm) not accessible. Software emulation is too slow."
        echo "  sudo gpasswd -a \$USER kvm  # then log out and back in."
        exit 1
    fi
    EMULATOR_BIN="$ANDROID_HOME/emulator/emulator"
    echo "No emulator running — booting AVD sharedinbox_test…"
    "$EMULATOR_BIN" -avd sharedinbox_test -no-window -no-audio -no-snapshot-save \
        > /tmp/emulator.log 2>&1 &
    for _i in $(seq 1 60); do
        EMULATOR_ID=$("$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
        [ -n "$EMULATOR_ID" ] && break
        sleep 2
    done
    [ -n "$EMULATOR_ID" ] || { echo "Emulator did not become ready within 120 s"; exit 1; }
    "$ADB" -s "$EMULATOR_ID" wait-for-device
    for _i in $(seq 1 30); do
        BOOT_DONE=$("$ADB" -s "$EMULATOR_ID" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$BOOT_DONE" = "1" ] && break
        sleep 2
    done
    [ "${BOOT_DONE:-0}" = "1" ] || { echo "Android boot did not complete within 60 s"; exit 1; }
fi
echo "Using emulator: $EMULATOR_ID"

echo "Installing split APKs from $APK_DIR…"
# install-multiple is required for split APKs from the Play generatedApks API.
mapfile -t APK_FILES < <(find "$APK_DIR" -maxdepth 1 -name "*.apk" -type f)
[ "${#APK_FILES[@]}" -gt 0 ] || { echo "No APKs in $APK_DIR"; exit 1; }
"$ADB" -s "$EMULATOR_ID" install-multiple -r "${APK_FILES[@]}"

echo "Clearing crash logcat buffer…"
"$ADB" -s "$EMULATOR_ID" logcat -b crash -c

echo "Launching $PACKAGE/.MainActivity…"
"$ADB" -s "$EMULATOR_ID" shell am start -W -n "$PACKAGE/.MainActivity"

WATCH_SECONDS=15
echo "Watching crash logcat for FATAL EXCEPTION for ${WATCH_SECONDS}s…"
crash_rc=0
CRASH_LOG=$(timeout "${WATCH_SECONDS}" "$ADB" -s "$EMULATOR_ID" logcat -b crash -d 2>&1) || crash_rc=$?
[ "$crash_rc" -eq 0 ] || { echo "ERROR: adb logcat -b crash -d failed (rc=$crash_rc): $CRASH_LOG"; exit 1; }
if echo "$CRASH_LOG" | grep -qE "FATAL EXCEPTION|Process .* has died"; then
    echo "----- CRASH DETECTED -----"
    echo "$CRASH_LOG"
    echo "--------------------------"
    exit 1
fi

echo "OK — no crash signal in ${WATCH_SECONDS}s for versionCode=$VERSION_CODE."
