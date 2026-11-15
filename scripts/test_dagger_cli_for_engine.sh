#!/usr/bin/env bash
# Tests for the "bump deadlock" fix: scripts/dagger_cli_for_engine.sh and the
# block in scripts/setup_dagger_remote.sh that uses it to make the runner's
# Dagger CLI match the engine. Serves a fake dl.dagger.io from a file:// dir.
#
# Run directly: bash scripts/test_dagger_cli_for_engine.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/dagger_cli_for_engine.sh"
SETUP="$SCRIPT_DIR/setup_dagger_remote.sh"

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); }
_fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

case "$(uname -m)" in x86_64 | amd64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac

# A fake release: a `dagger` that reports $1, tarred, plus checksums.txt.
make_release() {
    local v=$1 d="$T/dl/$1"
    mkdir -p "$d" "$T/build"
    printf '#!/usr/bin/env bash\necho "version:     v%s"\n' "$v" >"$T/build/dagger"
    chmod +x "$T/build/dagger"
    tar -czf "$d/dagger_v${v}_linux_${ARCH}.tar.gz" -C "$T/build" dagger
    (cd "$d" && sha256sum "dagger_v${v}_linux_${ARCH}.tar.gz" >checksums.txt)
}
make_release 9.9.9-beta.2
make_release 9.9.9-beta.3
# Corrupt the tarball after its checksum was recorded.
make_release 9.9.9-beta.4
echo junk >>"$T/dl/9.9.9-beta.4/dagger_v9.9.9-beta.4_linux_${ARCH}.tar.gz"

helper() { DAGGER_DL_BASE="file://$T/dl" DAGGER_CLI_CACHE="$T/cache" "$HELPER" "$@"; }

# --- helper: engine-style version string (v prefix, +commit) is normalised -----
out=$(helper v9.9.9-beta.2+400b82d6 2>&1); rc=$?
if [ "$rc" -ne 0 ] || [ "$out" != "$T/cache/9.9.9-beta.2" ]; then
    _fail "helper: should install into cache/9.9.9-beta.2 (rc=$rc)" "$out"
elif ! "$out/dagger" version | grep -q 'v9.9.9-beta.2'; then
    _fail "helper: installed binary is not the requested version"
else _pass; fi

# --- helper: second call is a cache hit (no download) ----------------------------
rm -rf "$T/dl/9.9.9-beta.2"
out=$(helper 9.9.9-beta.2 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$T/cache/9.9.9-beta.2" ] && _pass || _fail "helper: cache hit should not download" "$out"

# --- helper: checksum mismatch is refused, nothing cached ------------------------
out=$(helper 9.9.9-beta.4 2>&1); rc=$?
if [ "$rc" -eq 0 ] || ! printf '%s' "$out" | grep -q 'sha256 mismatch' || [ -e "$T/cache/9.9.9-beta.4" ]; then
    _fail "helper: corrupt tarball must fail and not be cached (rc=$rc)" "$out"
else _pass; fi

# --- helper: unknown version fails -----------------------------------------------
out=$(helper 9.9.9-beta.9 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'could not download' && _pass || _fail "helper: missing release should fail (rc=$rc)" "$out"

# --- helper: junk version is rejected before any URL is built ----------------------
out=$(helper '1.0;rm -rf /' 2>&1); rc=$?
[ "$rc" -eq 2 ] && _pass || _fail "helper: junk version should exit 2 (rc=$rc)" "$out"

# --- setup block ---------------------------------------------------------------------
snippet=$(awk '/^# Make the CLI match the engine/,/^# Verify the connection/' "$SETUP")
if [ -z "$snippet" ]; then
    echo "FAIL: could not locate the CLI-match block in $SETUP"
    exit 1
fi
mkdir -p "$T/bin"
# Baked-in CLI: reports v9.9.9-beta.2; `query` answers with $ENGINE_REPLY.
cat >"$T/bin/dagger" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    version) echo "version:     v9.9.9-beta.2" ;;
    query) cat >/dev/null; [ -n "${ENGINE_REPLY:-}" ] || exit 1; printf '{\n  "version": "%s"\n}\n' "$ENGINE_REPLY" ;;
esac
EOF
printf '#!/usr/bin/env bash\nshift\n"$@"\n' >"$T/bin/timeout"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/"*

run_block() {
    : >"$T/github_path"
    rm -rf "$T/cache"
    PATH="$T/bin:$PATH" DAGGER_DL_BASE="file://$T/dl" DAGGER_CLI_CACHE="$T/cache" \
        GITHUB_PATH="$T/github_path" \
        bash -c "set -euo pipefail; $snippet
echo \"RESOLVED=\$(dagger version | head -1)\"" "$SETUP" 2>&1
}

# --- engine ahead of the baked CLI: fetch, use it, and export it to later steps ---
out=$(ENGINE_REPLY="v9.9.9-beta.3+abc123" run_block); rc=$?
if [ "$rc" -ne 0 ]; then
    _fail "setup: engine ahead should succeed (rc=$rc)" "$out"
elif ! printf '%s' "$out" | grep -q 'RESOLVED=version:     v9.9.9-beta.3'; then
    _fail "setup: dagger on PATH should now be the engine's version" "$out"
elif [ "$(cat "$T/github_path")" != "$T/cache/9.9.9-beta.3" ]; then
    _fail "setup: CLI dir must be appended to GITHUB_PATH for later steps" "$(cat "$T/github_path")"
else _pass; fi

# --- engine equals the baked CLI: no download, nothing exported -------------------
out=$(ENGINE_REPLY="v9.9.9-beta.2+abc123" run_block); rc=$?
if [ "$rc" -ne 0 ] || [ -s "$T/github_path" ] || [ -e "$T/cache" ]; then
    _fail "setup: matching versions must not download (rc=$rc)" "$out"
else _pass; fi

# --- engine unreadable: warn, keep the baked CLI, let verify report it ---------------
out=$(ENGINE_REPLY="" run_block); rc=$?
if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q 'Could not read the engine version' \
    || ! printf '%s' "$out" | grep -q 'RESOLVED=version:     v9.9.9-beta.2'; then
    _fail "setup: unreadable engine should warn and keep baked CLI (rc=$rc)" "$out"
else _pass; fi

# --- engine on a version whose download is corrupt: fail the job loudly -------------
out=$(ENGINE_REPLY="v9.9.9-beta.4" run_block); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'sha256 mismatch' && _pass || _fail "setup: bad download must fail the job (rc=$rc)" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
