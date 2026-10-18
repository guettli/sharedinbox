#!/bin/bash
# Entrypoint of the ExploreLinux Dagger service (ci/main.go): bring up the
# virtual desktop, then hand over to scripts/explore_server.py, which launches
# the debug build of the app and exposes an HTTP API to drive it. See
# EXPLORATORY-TESTING.md.
set -euo pipefail

# shellcheck source=scripts/gui_session.sh
. "$(dirname "$0")/gui_session.sh"

# JMAP and ManageSieve too, so the agent can seed and inspect the mailbox
# through the same tunnel the app's IMAP/SMTP go through.
gui_session_forward_stalwart 8080:8080 4190:4190
gui_session_start_desktop

# A Secret Service for flutter_secure_storage (libsecret). Without one the app
# cannot store an account password and adding an account fails.
echo -n explore | gnome-keyring-daemon --unlock --components=secrets >/tmp/keyring.log 2>&1 || true

exec python3 "$(dirname "$0")/explore_server.py"
