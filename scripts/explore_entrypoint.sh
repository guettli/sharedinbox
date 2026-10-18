#!/bin/bash
# Entrypoint of the ExploreLinux Dagger service (ci/main.go): bring up the
# virtual desktop, then hand over to scripts/explore_server.py, which launches
# the debug build of the app and exposes an HTTP API to drive it. See
# EXPLORATORY-TESTING.md.
set -euo pipefail

# shellcheck source=scripts/gui_session.sh
. "$(dirname "$0")/gui_session.sh"

# JMAP, so the agent can inspect the mailbox through the same tunnel the app's
# IMAP/SMTP go through, and ManageSieve, which the app probes on localhost.
gui_session_forward_stalwart 8080:8080 4190:4190
gui_session_start_desktop

# explore_server.py starts the keyring (and restarts it on a wipe) and the app.
exec python3 "$(dirname "$0")/explore_server.py"
