#!/usr/bin/env bash
# Bash Strict Mode: https://github.com/guettli/bash-strict-mode
trap 'echo -e "\n🤷 🚨 🔥 Warning: A command has failed. Exiting the script. Line was ($0:$LINENO): $(sed -n "${LINENO}p" "$0" 2>/dev/null || true) 🔥 🚨 🤷 "; exit 3' ERR
set -Eeuo pipefail

: "${ANDROID_APK_SCP_HOST:?ANDROID_APK_SCP_HOST is not set (add it to .env)}"
: "${ANDROID_APK_SCP_USER:?ANDROID_APK_SCP_USER is not set (add it to .env)}"
: "${ANDROID_APK_SCP_PATH:?ANDROID_APK_SCP_PATH is not set (add it to .env)}"

scp -C build/app/outputs/flutter-apk/app-release.apk "${ANDROID_APK_SCP_USER}@${ANDROID_APK_SCP_HOST}:${ANDROID_APK_SCP_PATH}"
