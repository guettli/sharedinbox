#!/usr/bin/env bash
# CI monitor for guettli/sharedinbox on GitHub.
#
# Designed to run as a Kubernetes CronJob (see k8s/ci-monitor.yaml). The
# manifest's ConfigMap embeds a verbatim copy of this script; keep them in
# sync via scripts/check_ci_monitor_sync.sh.
#
# Looks at the latest CI run, classifies any failure, auto-fixes the few
# known deterministic patterns, and alerts via ntfy for anything ambiguous.
#
# Required env (provided by the agentloop-secrets Secret in-cluster):
#   GITHUB_TOKEN             token for GitHub, owned by guettlibot
#                            (push access to guettli/sharedinbox)
#   NTFY_ALERT_MESSAGE_URL   ntfy topic URL for human-readable alerts
#   CI_MONITOR_API           GitHub API base (e.g. https://api.github.com)
#   CI_MONITOR_REPO          owner/repo  (e.g. guettli/sharedinbox)
#   CI_MONITOR_BRANCH        branch to monitor (e.g. main)
#   CI_MONITOR_AUTO_FIX      "true" to push Pattern A fixes, else "false"
#                            (alert-only until the runner pool is stable)
#
# Optional env:
#   CI_MONITOR_WORKDIR       scratch dir (default mktemp -d)
#
# When sourced (BASH_SOURCE != argv0) the file exposes the pure helpers
# without running main() — used by scripts/test_ci_monitor.sh.

set -uo pipefail

log() {
    printf '%s ci-monitor: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Query the GitHub REST API with the bearer token. Args: path (e.g. repos/...).
gh_api() {
    local path="$1"
    curl -sf \
        -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$CI_MONITOR_API/$path"
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

# Locate the workflow file that defines the failing job. Echoes the matching
# path or nothing if not found.
locate_workflow_file() {
    local root="$1" name="$2" candidate
    for candidate in "$root/.github/workflows/$name.yml" "$root/.github/workflows/$name.yaml"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return
        fi
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

# Echo the first registered, non-offline self-hosted runner label visible for
# the repo, or return non-zero on failure. Callers must check the exit
# status — no silent fallback, since guessing a label the runner pool
# doesn't actually publish would just push a broken workflow.
discover_runner_label() {
    local repo="$1" json label
    json=$(gh_api "repos/$repo/actions/runners") || return 1
    label=$(printf '%s' "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('runners', []):
    if r.get('status') == 'offline':
        continue
    for lbl in r.get('labels', []) or []:
        name = lbl if isinstance(lbl, str) else lbl.get('name', '')
        if name and name not in ('self-hosted', 'Linux', 'X64'):
            print(name)
            sys.exit(0)
") || return 1
    [ -n "$label" ] || return 1
    echo "$label"
}

main() {
    : "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
    : "${CI_MONITOR_API:?CI_MONITOR_API must be set (e.g. https://api.github.com)}"
    : "${CI_MONITOR_REPO:?CI_MONITOR_REPO must be set (e.g. guettli/sharedinbox)}"
    : "${CI_MONITOR_BRANCH:?CI_MONITOR_BRANCH must be set (e.g. main)}"
    : "${CI_MONITOR_AUTO_FIX:?CI_MONITOR_AUTO_FIX must be set (true or false)}"

    local workdir="${CI_MONITOR_WORKDIR:-$(mktemp -d)}"
    trap 'rm -rf "$workdir"' EXIT

    local repo="$CI_MONITOR_REPO"
    log "polling https://github.com/$repo (branch $CI_MONITOR_BRANCH)"

    local runs_json
    runs_json=$(gh_api "repos/$repo/actions/runs?branch=$CI_MONITOR_BRANCH&per_page=10") || {
        log "ERROR: could not fetch runs list"
        ntfy_alert "GitHub CI monitor: API unreachable" \
            "Failed to query $CI_MONITOR_API/repos/$repo/actions/runs. Check token / network."
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
        'workflow_id': r.get('name') or r.get('workflow_id') or '',
    }))
    break
" 2>/dev/null) || true

    if [ -z "$latest" ]; then
        log "no non-skipped runs found; nothing to do"
        exit 0
    fi

    local status conclusion run_id run_number workflow_name
    run_id=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('id') or '')")
    status=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status') or '')")
    conclusion=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('conclusion') or '')")
    run_number=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('run_number') or '')")
    workflow_name=$(printf '%s' "$latest" | python3 -c "import json,sys;print(json.load(sys.stdin).get('workflow_id') or '')")

    log "latest run: #$run_number (id=$run_id) status=$status conclusion=$conclusion workflow=$workflow_name"

    if [ "$status" != "completed" ] || [ "$conclusion" = "success" ] || [ "$conclusion" = "skipped" ]; then
        log "CI is healthy"
        exit 0
    fi

    local logs_url="https://github.com/$repo/actions/runs/$run_id"
    # Fetch the failed-step logs via the gh CLI. Required — the previous REST
    # fallback returned a zip that grep would happily "match" against binary
    # noise, silently producing bogus classifications.
    if ! command -v gh >/dev/null 2>&1; then
        log "ERROR: gh CLI is required to fetch run logs"
        ntfy_alert "GitHub CI monitor: gh CLI missing" \
            "ci-monitor requires the gh CLI on the pod image to fetch run logs."
        exit 1
    fi
    local logs
    logs=$(GH_TOKEN="$GITHUB_TOKEN" gh run view "$run_id" --log-failed -R "$repo" 2>/dev/null || true)
    if [ -z "$logs" ]; then
        logs=$(GH_TOKEN="$GITHUB_TOKEN" gh run view "$run_id" --log -R "$repo" 2>/dev/null || true)
    fi

    local pattern
    pattern=$(classify_failure "$logs")
    log "diagnosed pattern: $pattern"

    case "$pattern" in
        A)
            if [ "$CI_MONITOR_AUTO_FIX" != "true" ]; then
                ntfy_alert "GitHub CI: runner-label mismatch (Pattern A)" \
                    "Run #$run_number ($workflow_name) failed with a workspace/runner-label issue. CI_MONITOR_AUTO_FIX is off — fix manually."
                exit 0
            fi
            log "Pattern A: attempting auto-fix"
            local label
            if ! label=$(discover_runner_label "$repo"); then
                log "ERROR: could not discover a runner label for $repo"
                ntfy_alert "GitHub CI monitor: runner label lookup failed" \
                    "Pattern A on run #$run_number but no online non-generic runner label could be discovered in $repo — manual fix required."
                exit 1
            fi
            log "discovered runner label: $label"

            local clone="$workdir/repo"
            git clone --depth 1 --branch "$CI_MONITOR_BRANCH" \
                "https://x-access-token:$GITHUB_TOKEN@github.com/$repo.git" "$clone" || {
                ntfy_alert "GitHub CI monitor: clone failed" "Could not clone $repo to apply Pattern A fix."
                exit 1
            }
            git -C "$clone" config user.email "ci-monitor@github.invalid"
            git -C "$clone" config user.name "ci-monitor"

            local wf_file
            wf_file=$(locate_workflow_file "$clone" "ci")
            if [ -z "$wf_file" ]; then
                ntfy_alert "GitHub CI monitor: workflow file not found" \
                    "Pattern A detected on run #$run_number but no ci workflow file found in $repo."
                exit 0
            fi
            log "patching $wf_file -> runs-on: $label"

            patch_runs_on "$wf_file" "$label"
            local rc=$?
            if [ $rc -eq 2 ]; then
                ntfy_alert "GitHub CI monitor: no runs-on line" \
                    "Pattern A on run #$run_number but $(basename "$wf_file") has no runs-on line."
                exit 0
            fi
            if [ $rc -eq 1 ]; then
                log "workflow already uses $label; nothing to push"
                ntfy_alert "GitHub CI monitor: Pattern A but no diff" \
                    "Run #$run_number diagnosed as Pattern A but workflow already targets $label. Manual review needed."
                exit 0
            fi

            git -C "$clone" add -A
            git -C "$clone" commit -m "ci: switch runs-on to $label (auto-fix Pattern A from ci-monitor)"
            if ! git -C "$clone" push origin "$CI_MONITOR_BRANCH"; then
                ntfy_alert "GitHub CI monitor: push failed" \
                    "Pattern A fix committed locally but could not push to $repo. Investigate."
                exit 1
            fi
            log "pushed Pattern A fix"
            ntfy_alert "GitHub CI: auto-fixed Pattern A" \
                "Switched runs-on to '$label' on $CI_MONITOR_BRANCH (run #$run_number)."
            ;;
        B)
            log "Pattern B (transient Dagger): no action"
            ;;
        C)
            ntfy_alert "GitHub CI: ci/main.go compile error (Pattern C)" \
                "Run #$run_number ($workflow_name) failed with a Dagger/Go compile error. Needs human attention."
            ;;
        D)
            ntfy_alert "GitHub CI: Flutter/Dart failure (Pattern D)" \
                "Run #$run_number ($workflow_name) failed inside the Flutter app. Needs human attention."
            ;;
        U|*)
            ntfy_alert "GitHub CI: unknown failure" \
                "Run #$run_number ($workflow_name) failed for an unclassified reason. Logs: $logs_url"
            ;;
    esac
}

# Only execute main() when the script is run directly, not when sourced
# (e.g. by scripts/test_ci_monitor.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
