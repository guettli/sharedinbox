#!/usr/bin/env bash
# CI monitor for guettli/sharedinbox on sialoop.
#
# Designed to run as a Kubernetes CronJob (see k8s/ci-monitor.yaml). The
# manifest's ConfigMap embeds a verbatim copy of this script; keep them in
# sync via scripts/check_ci_monitor_sync.sh.
#
# Looks at the latest CI run, classifies any failure, auto-fixes the few
# known deterministic patterns, and alerts via ntfy for anything ambiguous.
#
# Required env (provided by the agentloop-secrets Secret in-cluster):
#   GITEA_TOKEN              token for sialoop.thomas-guettler.de, owned by
#                            guettlibot (push access to guettli/sharedinbox)
#   NTFY_ALERT_MESSAGE_URL   ntfy topic URL for human-readable alerts
#
# Optional env:
#   CI_MONITOR_AUTO_FIX      "true" to push Pattern A fixes; default "false"
#                            (alert-only until the runner pool is stable)
#   CI_MONITOR_HOST          Gitea host (default sialoop.thomas-guettler.de)
#   CI_MONITOR_REPO          owner/repo  (default guettli/sharedinbox)
#   CI_MONITOR_BRANCH        branch to monitor (default main)
#   CI_MONITOR_WORKDIR       scratch dir (default mktemp -d)
#
# When sourced (BASH_SOURCE != argv0) the file exposes the pure helpers
# without running main() — used by scripts/test_ci_monitor.sh.

set -uo pipefail

CI_MONITOR_HOST="${CI_MONITOR_HOST:-sialoop.thomas-guettler.de}"
CI_MONITOR_REPO="${CI_MONITOR_REPO:-guettli/sharedinbox}"
CI_MONITOR_BRANCH="${CI_MONITOR_BRANCH:-main}"
CI_MONITOR_AUTO_FIX="${CI_MONITOR_AUTO_FIX:-false}"

log() {
    printf '%s ci-monitor: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Diagnose a CI failure from log content. Echoes one of:
#   A  workspace permission / wrong runs-on runner label
#   B  Dagger 'No Dagger server responded' (transient)
#   C  Go/Dagger compile error in ci/main.go
#   D  Flutter/Dart application failure
#   U  unknown
# Order matters: B is checked before C because a transient Dagger failure
# can surface a misleading 'ci/main.go' line in the trace.
classify_failure() {
    local logs="$1"

    if printf '%s' "$logs" | grep -qE "no matching runner|no runner matches|workspace.*permission|EACCES|Permission denied.*workspace|runs-on.*not found"; then
        echo A
        return
    fi

    if printf '%s' "$logs" | grep -qE "No Dagger server responded|dagger.*connection refused|failed to connect to dagger engine|dagger engine.*not.*ready"; then
        echo B
        return
    fi

    if printf '%s' "$logs" | grep -qE "ci/main\.go:[0-9]+:[0-9]+:|cannot find package.*ci/|undefined:.*\(in ci/|go build.*ci/main\.go"; then
        echo C
        return
    fi

    if printf '%s' "$logs" | grep -qE "lib/.*\.dart:[0-9]+:[0-9]+:|flutter.*test.*FAIL|flutter build.*failed|dart analyze.*error|Compilation failed.*\.dart"; then
        echo D
        return
    fi

    echo U
}

# Locate the workflow file that defines the failing job. Tries the three
# conventional directories in priority order. Echoes the matching path or
# nothing if not found.
locate_workflow_file() {
    local root="$1" name="$2" dir candidate
    for dir in .gitea/workflows .forgejo/workflows .github/workflows; do
        for candidate in "$root/$dir/$name.yml" "$root/$dir/$name.yaml"; do
            if [ -f "$candidate" ]; then
                echo "$candidate"
                return
            fi
        done
    done
}

# Replace the runs-on label in a workflow file. Returns 0 if a change was
# made, 1 if the file already used the wanted label, 2 if no runs-on line
# was found.
patch_runs_on() {
    local file="$1" wanted="$2" current
    current=$(grep -E '^\s*runs-on:' "$file" | head -n1 | sed -E 's/.*runs-on:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs || true)
    if [ -z "$current" ]; then
        return 2
    fi
    if [ "$current" = "$wanted" ]; then
        return 1
    fi
    sed -i.bak -E "s|(runs-on:[[:space:]]*).*|\1$wanted|" "$file"
    rm -f "$file.bak"
    return 0
}

# Send an ntfy alert. Silent on success, non-fatal on failure (the script
# should keep running so its exit reflects the CI status, not the alert).
ntfy_alert() {
    local title="$1" body="$2"
    if [ -z "${NTFY_ALERT_MESSAGE_URL:-}" ]; then
        log "WARN: NTFY_ALERT_MESSAGE_URL unset; would have alerted: $title"
        return 0
    fi
    curl -sf -X POST \
        -H "Title: $title" \
        -H "Priority: high" \
        -H "Tags: warning,robot" \
        -d "$body" \
        "$NTFY_ALERT_MESSAGE_URL" >/dev/null || log "WARN: ntfy POST failed"
}

# Echo the first registered, non-offline runner label visible for the repo.
# Falls back to 'ubuntu-latest' if no labels can be discovered.
discover_runner_label() {
    local host="$1" repo="$2" json
    json=$(curl -sf -H "Authorization: token ${GITEA_TOKEN:-}" \
        "https://$host/api/v1/repos/$repo/actions/runners" 2>/dev/null) || true
    if [ -z "$json" ]; then
        echo "ubuntu-latest"
        return
    fi
    local label
    label=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in data.get('runners', []):
    if r.get('status') == 'offline':
        continue
    for lbl in r.get('labels', []) or []:
        name = lbl if isinstance(lbl, str) else lbl.get('name', '')
        if name:
            print(name)
            sys.exit(0)
" 2>/dev/null || true)
    if [ -n "$label" ]; then
        echo "$label"
        return
    fi
    echo "ubuntu-latest"
}

main() {
    : "${GITEA_TOKEN:?GITEA_TOKEN must be set}"

    local workdir="${CI_MONITOR_WORKDIR:-$(mktemp -d)}"
    trap 'rm -rf "$workdir"' EXIT

    local host="$CI_MONITOR_HOST" repo="$CI_MONITOR_REPO"
    log "polling https://$host/$repo (branch $CI_MONITOR_BRANCH)"

    local runs_json
    runs_json=$(curl -sf -H "Authorization: token $GITEA_TOKEN" \
        "https://$host/api/v1/repos/$repo/actions/tasks?limit=10") || {
        log "ERROR: could not fetch tasks list"
        ntfy_alert "sialoop CI monitor: API unreachable" \
            "Failed to query https://$host/api/v1/repos/$repo/actions/tasks. Check token / network."
        exit 1
    }

    local latest
    latest=$(printf '%s' "$runs_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('workflow_runs', []):
    if r.get('status') == 'skipped':
        continue
    print(json.dumps({
        'id': r.get('id'),
        'run_number': r.get('run_number'),
        'status': r.get('status'),
        'conclusion': r.get('conclusion'),
        'head_branch': r.get('head_branch'),
        'workflow_id': r.get('workflow_id') or r.get('name') or '',
    }))
    break
" 2>/dev/null) || true

    if [ -z "$latest" ]; then
        log "no non-skipped runs found; nothing to do"
        exit 0
    fi

    local status conclusion run_number workflow_name
    status=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status') or '')")
    conclusion=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('conclusion') or '')")
    run_number=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('run_number') or '')")
    workflow_name=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('workflow_id') or '')")

    log "latest run: #$run_number status=$status conclusion=$conclusion workflow=$workflow_name"

    if [ "$status" != "completed" ] || [ "$conclusion" = "success" ] || [ "$conclusion" = "skipped" ]; then
        log "CI is healthy"
        exit 0
    fi

    local logs_url="https://$host/$repo/actions/runs/$run_number/logs"
    local logs
    logs=$(curl -sf -H "Authorization: token $GITEA_TOKEN" "$logs_url" 2>/dev/null || true)
    if [ -z "$logs" ]; then
        local job_url="https://$host/$repo/actions/runs/$run_number/jobs/0/attempt/1/logs"
        logs=$(curl -sf -H "Authorization: token $GITEA_TOKEN" "$job_url" 2>/dev/null || true)
    fi

    local pattern
    pattern=$(classify_failure "$logs")
    log "diagnosed pattern: $pattern"

    case "$pattern" in
        A)
            if [ "$CI_MONITOR_AUTO_FIX" != "true" ]; then
                ntfy_alert "sialoop CI: runner-label mismatch (Pattern A)" \
                    "Run #$run_number ($workflow_name) failed with a workspace/runner-label issue. CI_MONITOR_AUTO_FIX is off — fix manually."
                exit 0
            fi
            log "Pattern A: attempting auto-fix"
            local label
            label=$(discover_runner_label "$host" "$repo")
            log "discovered runner label: $label"

            local clone="$workdir/repo"
            git clone --depth 1 --branch "$CI_MONITOR_BRANCH" \
                "https://oauth2:$GITEA_TOKEN@$host/$repo.git" "$clone" || {
                ntfy_alert "sialoop CI monitor: clone failed" "Could not clone $repo to apply Pattern A fix."
                exit 1
            }
            git -C "$clone" config user.email "ci-monitor@sialoop.invalid"
            git -C "$clone" config user.name "ci-monitor"

            local wf_file
            wf_file=$(locate_workflow_file "$clone" "ci")
            if [ -z "$wf_file" ]; then
                ntfy_alert "sialoop CI monitor: workflow file not found" \
                    "Pattern A detected on run #$run_number but no ci workflow file found in $repo."
                exit 0
            fi
            log "patching $wf_file -> runs-on: $label"

            patch_runs_on "$wf_file" "$label"
            local rc=$?
            if [ $rc -eq 2 ]; then
                ntfy_alert "sialoop CI monitor: no runs-on line" \
                    "Pattern A on run #$run_number but $(basename "$wf_file") has no runs-on line."
                exit 0
            fi
            if [ $rc -eq 1 ]; then
                log "workflow already uses $label; nothing to push"
                ntfy_alert "sialoop CI monitor: Pattern A but no diff" \
                    "Run #$run_number diagnosed as Pattern A but workflow already targets $label. Manual review needed."
                exit 0
            fi

            git -C "$clone" add -A
            git -C "$clone" commit -m "ci: switch runs-on to $label (auto-fix Pattern A from ci-monitor)"
            if ! git -C "$clone" push origin "$CI_MONITOR_BRANCH"; then
                ntfy_alert "sialoop CI monitor: push failed" \
                    "Pattern A fix committed locally but could not push to $repo. Investigate."
                exit 1
            fi
            log "pushed Pattern A fix"
            ntfy_alert "sialoop CI: auto-fixed Pattern A" \
                "Switched runs-on to '$label' on $CI_MONITOR_BRANCH (run #$run_number)."
            ;;
        B)
            log "Pattern B (transient Dagger): no action"
            ;;
        C)
            ntfy_alert "sialoop CI: ci/main.go compile error (Pattern C)" \
                "Run #$run_number ($workflow_name) failed with a Dagger/Go compile error. Needs human attention."
            ;;
        D)
            ntfy_alert "sialoop CI: Flutter/Dart failure (Pattern D)" \
                "Run #$run_number ($workflow_name) failed inside the Flutter app. Needs human attention."
            ;;
        U|*)
            ntfy_alert "sialoop CI: unknown failure" \
                "Run #$run_number ($workflow_name) failed for an unclassified reason. Logs: $logs_url"
            ;;
    esac
}

# Only execute main() when the script is run directly, not when sourced
# (e.g. by scripts/test_ci_monitor.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
