#!/usr/bin/env bash
# Bash Strict Mode: https://github.com/guettli/bash-strict-mode
trap 'echo -e "\n🤷 🚨 🔥 Warning: A command has failed. Exiting the script. Line was ($0:$LINENO): $(sed -n "${LINENO}p" "$0" 2>/dev/null || true) 🔥 🚨 🤷 "; exit 3' ERR
set -Eeuo pipefail

if [ -z "${ANDROID_APK_SCP_HOST:-}" ] || [ -z "${ANDROID_APK_SCP_USER:-}" ] || [ -z "${ANDROID_APK_SCP_PATH:-}" ]; then
    echo "ERROR: ANDROID_APK_SCP_HOST, ANDROID_APK_SCP_USER, and ANDROID_APK_SCP_PATH must be set in .env"
    exit 1
fi

scp -C build/app/outputs/flutter-apk/app-release.apk "${ANDROID_APK_SCP_USER}@${ANDROID_APK_SCP_HOST}:${ANDROID_APK_SCP_PATH}"

curl -d 'Deployed to https://thomas-guettler.de/si3.apk' https://ntfy.sh/ClaudeGuettliNotification265746942
