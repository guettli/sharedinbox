#!/usr/bin/env bash
# Wrap a Dagger invocation with retries for transient engine errors. On "No
# space left on device" the local cache is pruned before the next attempt. On
# success the captured output is suppressed; on final failure it is replayed
# (same contract as silent_on_success.sh) so CI logs stay quiet when
# everything works.
set -uo pipefail

out=$(mktemp)
trap 'rm -f "$out"' EXIT

_ts() { date -u '+[%H:%M:%S]'; }

rc=0
for attempt in 1 2 3; do
    : > "$out"
    rc=0
    "$@" > "$out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        exit 0
    fi
    if [ "$attempt" -lt 3 ] && grep -q "No space left on device" "$out"; then
        echo "$(_ts) dagger: disk space error on attempt $attempt/3, pruning Dagger cache..." >&2
        prune_rc=0
        for prune_attempt in 1 2 3; do
            prune_rc=0
            timeout 120 dagger query '{ engine { localCache { prune(targetSpace: "20gb") } } }' >/dev/null || prune_rc=$?
            if [ "$prune_rc" -eq 0 ]; then
                break
            fi
            echo "$(_ts) dagger: prune attempt $prune_attempt/3 failed (exit $prune_rc)" >&2
            [ "$prune_attempt" -lt 3 ] && sleep 10
        done
        if [ "$prune_rc" -ne 0 ]; then
            echo "$(_ts) dagger: prune failed after 3 attempts; aborting" >&2
            cat "$out"
            exit "$rc"
        fi
        echo "$(_ts) dagger: waiting 90s for freed space to settle..." >&2
        sleep 90
        continue
    fi
    if [ "$attempt" -lt 3 ] && grep -qE "connection reset|context deadline exceeded|connection refused|invalid return status code|TLS handshake timeout|failed to fetch (anonymous )?token|failed to do request|i/o timeout" "$out"; then
        echo "$(_ts) dagger: network error on attempt $attempt/3, retrying..." >&2
        continue
    fi
    cat "$out"
    exit "$rc"
done

cat "$out"
exit "$rc"
