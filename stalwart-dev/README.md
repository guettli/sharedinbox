# stalwart-dev — local Stalwart for probing server behavior

Several sync-engine fixes turned on *how a real JMAP server actually behaves*,
not on what the RFC says — and the cheapest way to settle those questions is to
ask a throwaway Stalwart directly. Examples this answered:

- `Email/changes` honours `maxChanges` / `hasMoreChanges` and does **not**
  degrade to `cannotCalculateChanges` (#968).
- `Email/get` with `ids: []` returns the Email `state`, even on an empty
  mailbox (#973).
- `Email/get` populates `notFound` for ids the server no longer has, including
  alongside the body-fetch options (#980).
- `Email/query` `anchor`/`anchorOffset` resumes correctly where `position`
  skips messages after a deletion; a deleted anchor returns `anchorNotFound`;
  `queryState` changes when the result set shifts (#1020).
- `maxObjectsInGet` is 500, so the 50-id `Email/get` batch is safely under it.

## 1. Start a throwaway Stalwart

`config.toml` here defines test accounts `alice@example.com` / `bob@example.com`,
both with password `secret`.

On a **codeN seat**, docker is root-only, so start it on `tc` as root and map a
local port (nothing else needs the container — delete it when done):

```
ssh root@tc 'docker run -d --name sbprobe --entrypoint stalwart \
  -p 127.0.0.1:18080:8080 \
  -v /home/$USER/sharedinbox/stalwart-dev/config.toml:/etc/stalwart/config.toml:ro \
  -v /tmp/sbprobe:/tmp/stalwart:rw \
  docker.io/stalwartlabs/stalwart:v0.14.1 --config /etc/stalwart/config.toml'
# … probe (below) …
ssh root@tc 'docker rm -f sbprobe; rm -rf /tmp/sbprobe'
```

Inside `nix develop` (with a container runtime and Flutter SDK), the existing
`./start` script does the same with random ports — see its header.

## 2. Probe it

`jmap_probe.py` is dependency-free (stdlib only). With no `--call` it prints a
session summary (apiUrl, accountId, `maxObjectsInGet`) and runs a read-only
demo:

```
python3 stalwart-dev/jmap_probe.py http://127.0.0.1:18080 alice@example.com secret
```

Pass `--call METHOD ARGS_JSON` (repeatable) to ask a specific question;
`accountId` is injected for you:

```
python3 stalwart-dev/jmap_probe.py http://127.0.0.1:18080 alice@example.com secret \
  --call Email/changes '{"sinceState":"s0","maxChanges":2}' \
  --call Email/get '{"ids":[],"fetchTextBodyValues":true}'
```

To reproduce the examples at the top, create a few messages first (an
`Email/set` `--call` with a `create` object) and then query/change against them.
```
