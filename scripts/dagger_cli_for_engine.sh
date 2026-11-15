#!/usr/bin/env bash
# Usage: scripts/dagger_cli_for_engine.sh <engine-version>
#
# Make sure a Dagger CLI of exactly <engine-version> (e.g. 1.0.0-beta.27, with
# or without a leading "v" or a "+commit" build suffix) is available, and print
# the directory that holds it. The caller prepends that directory to PATH.
#
# Why: CLI and engine must be the same version, and the CLI used to come only
# from the sharedinbox-ci-runner image, which is published from main. A PR that
# bumps Dagger therefore ran on a runner whose CLI no longer matched the engine
# (gitops bumps the engine first) and could not pass its own CI -- the "bump
# deadlock", worked around twice by hand-tagging a runner image. Now the runner
# downloads the CLI the engine asks for; the image's baked-in CLI is only a
# fast path.
#
# The tarball is verified against dl.dagger.io's checksums.txt for that
# version, as install.sh does, but without running a remote script.
# Downloads are cached per version under $DAGGER_CLI_CACHE.
#
# Env (for tests): DAGGER_DL_BASE (default https://dl.dagger.io/dagger/releases),
# DAGGER_CLI_CACHE (default ${XDG_CACHE_HOME:-$HOME/.cache}/sharedinbox/dagger-cli).
set -euo pipefail

raw=${1:-}
version=${raw#v}
version=${version%%+*}
# Strict: this string ends up in a URL and a path.
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "ERROR: dagger_cli_for_engine.sh: not a Dagger version: '${raw}'" >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "ERROR: dagger_cli_for_engine.sh: unsupported arch $(uname -m)" >&2; exit 2 ;;
esac

base=${DAGGER_DL_BASE:-https://dl.dagger.io/dagger/releases}
cache=${DAGGER_CLI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sharedinbox/dagger-cli}
dir="$cache/$version"

if [ -x "$dir/dagger" ]; then
  echo "$dir"
  exit 0
fi

tarball="dagger_v${version}_linux_${arch}.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }

if ! fetch "$base/$version/checksums.txt" "$tmp/checksums.txt"; then
  echo "ERROR: could not download $base/$version/checksums.txt" >&2
  exit 1
fi
want=$(awk -v f="$tarball" '$2 == f { print $1 }' "$tmp/checksums.txt")
if ! [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: no sha256 for $tarball in $base/$version/checksums.txt" >&2
  exit 1
fi
if ! fetch "$base/$version/$tarball" "$tmp/$tarball"; then
  echo "ERROR: could not download $base/$version/$tarball" >&2
  exit 1
fi
got=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
  echo "ERROR: sha256 mismatch for $tarball: got $got, checksums.txt says $want" >&2
  exit 1
fi

tar --no-same-owner -xzf "$tmp/$tarball" -C "$tmp" dagger
mkdir -p "$cache"
# Stage then rename so a concurrent or interrupted run never leaves a
# half-written binary at the cached path.
stage=$(mktemp -d "$cache/.stage.XXXXXX")
install -m 0755 "$tmp/dagger" "$stage/dagger"
if ! mv -T "$stage" "$dir" 2>/dev/null; then
  rm -rf "$stage" # lost a race; the winner's copy is equally verified
fi
echo "$dir"
