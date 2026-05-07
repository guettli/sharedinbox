#!/usr/bin/env bash
# Boot the sharedinbox_test AVD if no emulator is running, then launch the app
# interactively with flutter run.
#
# Run inside nix develop:
#   stalwart-dev/run_android.sh
set -Eeuo pipefail

ADB=$(command -v adb 2>/dev/null || echo "${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb")
"$ADB" version >/dev/null 2>&1 || {
    echo "adb not found — set ANDROID_HOME or add platform-tools to PATH"
    exit 1
}

# Ensure adb daemon is running before querying/starting the emulator.
"$ADB" start-server >/dev/null 2>&1 || true

EMULATOR_ID=$("$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
if [ -z "$EMULATOR_ID" ]; then
    # Check for KVM before starting.
    if [ ! -c /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "ERROR: KVM (/dev/kvm) not accessible. Software emulation is too slow."
        echo "Run these commands to fix permissions:"
        echo "  sudo groupadd -r kvm || true"
        echo "  sudo gpasswd -a \$USER kvm"
        echo "  # Then log out and back in."
        exit 1
    fi

    EMULATOR_BIN="${ANDROID_HOME:-$HOME/Android/Sdk}/emulator/emulator"
    echo "No emulator running — booting AVD sharedinbox_test..."
    "$EMULATOR_BIN" -avd sharedinbox_test -no-audio -no-snapshot-save &
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
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fvm flutter run -d "$EMULATOR_ID" --no-pub
