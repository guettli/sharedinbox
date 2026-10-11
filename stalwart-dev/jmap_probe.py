#!/usr/bin/env python3
"""Probe a JMAP server to see how it actually behaves.

Several sync-engine decisions turn on server semantics that are cheaper to
observe than to argue from the RFC (does `Email/changes` honour `maxChanges`?
does `Email/get` populate `notFound`? does `anchor` paging survive a deletion
where `position` does not?). This is a dependency-free way to ask the server
directly, against a throwaway Stalwart (see stalwart-dev/README.md).

Usage:
    jmap_probe.py BASE_URL USER PASS                 # session summary + a demo
    jmap_probe.py BASE_URL USER PASS \\
        --call Email/query '{"filter":{"inMailbox":"a"},"limit":3}' \\
        --call Email/get   '{"ids":[]}'              # run specific method calls

`--call METHOD ARGS_JSON` may be repeated; `accountId` is injected into each
args object automatically. Without any `--call`, a read-only demo runs.
"""
import base64
import json
import sys
import urllib.request
from urllib.parse import urlparse

CORE = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    base, user, password = argv[0], argv[1], argv[2]
    calls_spec = []
    i = 3
    while i < len(argv):
        if argv[i] == "--call" and i + 2 < len(argv):
            calls_spec.append((argv[i + 1], json.loads(argv[i + 2])))
            i += 3
        else:
            print(f"unexpected argument: {argv[i]}")
            return 2

    auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def req(url, data=None, method="GET"):
        r = urllib.request.Request(url, data=data, method=method)
        r.add_header("Authorization", auth)
        if data is not None:
            r.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(r, timeout=20) as f:
            return json.loads(f.read())

    session = req(base.rstrip("/") + "/.well-known/jmap")
    # apiUrl may be absolute or host-relative; resolve against BASE either way.
    api = session["apiUrl"]
    if urlparse(api).scheme == "":
        api = base.rstrip("/") + api
    else:
        api = base.rstrip("/") + urlparse(api).path
    primary = session.get("primaryAccounts") or {}
    account = (primary.get("urn:ietf:params:jmap:mail")
               or primary.get("urn:ietf:params:jmap:core")
               or next(iter(session.get("accounts") or {}), None))
    core_caps = (session.get("capabilities") or {}).get(
        "urn:ietf:params:jmap:core", {})
    print(f"apiUrl       : {api}")
    print(f"accountId    : {account}")
    print(f"maxObjectsInGet : {core_caps.get('maxObjectsInGet')}")
    print(f"maxObjectsInSet : {core_caps.get('maxObjectsInSet')}")

    def call(method_calls):
        body = json.dumps({"using": CORE, "methodCalls": method_calls})
        return req(api, data=body.encode(), method="POST")["methodResponses"]

    if not calls_spec:
        # Read-only demo: the inbox id, then its first few ids, then the
        # Email state (the id-less Email/get the full sync relies on).
        mb = call([["Mailbox/query",
                    {"accountId": account, "filter": {"role": "inbox"}}, "0"]])
        inbox = (mb[0][1].get("ids") or [None])[0]
        print(f"inbox        : {inbox}")
        calls_spec = [
            ("Email/query",
             {"filter": {"inMailbox": inbox}, "limit": 3,
              "calculateTotal": True}),
            ("Email/get", {"ids": []}),
        ]

    for method, args in calls_spec:
        args = {"accountId": account, **args}
        resp = call([[method, args, "0"]])[0]
        print(f"\n--- {method} {json.dumps(args)} ---")
        print(json.dumps(resp, indent=2)[:1200])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
