#!/usr/bin/env python3
"""Duplicated-code detector orchestrator.

Runs three tools — jscpd (Dart + Shell), pylint --enable=duplicate-code
(Python), and dupl (Go) — collects their findings into a canonical form and,
in --against-baseline mode, exits non-zero only when clones are found that are
NOT already recorded in duplication-baseline.json.

Findings are keyed by a content hash of the duplicated block so a clone stays
recognisable across small edits (whitespace, renamed imports) and file moves.

Usage:
  detect_duplication.py                # run all tools, print findings, exit 0
  detect_duplication.py --against-baseline
                                       # exit 1 if any finding is NOT in baseline
  detect_duplication.py --baseline     # overwrite duplication-baseline.json
                                       # with current findings (seeding)
  detect_duplication.py --changed-only # limit detection to files listed in
                                       # DUPLICATION_CHANGED_FILES env var
                                       # (used by the pre-commit wrapper)
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
REPORT_DIR = REPO_ROOT / "build" / "duplication"
BASELINE_PATH = REPO_ROOT / "duplication-baseline.json"


# Paths that are excluded from every tool. Generated files, platform
# scaffolding, and vendored binaries never produce actionable clone reports.
GLOBAL_EXCLUDES = (
    ".dart_tool/",
    "android/",
    "assets/",
    "build/",
    "drift_schemas/",
    "duplication-baseline.json",
    "ios/",
    "linux/",
    "macos/",
    "node_modules/",
    "playstore/",
    "arc-runner-image/",
    "web/",
    "website/",
    "windows/",
)


@dataclasses.dataclass(frozen=True, order=True)
class Clone:
    """A single duplication finding, normalised across tools.

    file/start/end describe one occurrence; ``key`` identifies the *pair* and
    is used to diff findings against the baseline. Two occurrences of the same
    clone share the same key.
    """

    tool: str
    file: str
    start_line: int
    end_line: int
    key: str  # hash of (sorted paths + block content)

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _relpath(path: str | Path) -> str:
    """Best-effort repo-relative POSIX path."""
    p = Path(path)
    if p.is_absolute():
        try:
            p = p.relative_to(REPO_ROOT)
        except ValueError:
            return p.as_posix()
    return p.as_posix()


def _excluded(rel_path: str) -> bool:
    return any(rel_path.startswith(pref) or ("/" + pref) in ("/" + rel_path)
               for pref in GLOBAL_EXCLUDES)


def _hash_block(lines: list[str]) -> str:
    """Content-hash of a duplicated block, whitespace-normalised.

    Whitespace-only differences must not create a "new" clone (they'd force a
    baseline refresh for a formatting change), so we collapse runs of
    whitespace before hashing.
    """
    joined = "\n".join(re.sub(r"\s+", " ", line).strip() for line in lines)
    return hashlib.sha256(joined.encode("utf-8", errors="replace")).hexdigest()[:16]


def _read_block(rel_path: str, start: int, end: int) -> list[str]:
    path = REPO_ROOT / rel_path
    if not path.is_file():
        return []
    try:
        text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    start_i = max(0, start - 1)
    end_i = min(len(text), end)
    return text[start_i:end_i]


def _run(cmd: list[str], *, cwd: Path | None = None,
         ok_codes: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess:
    """subprocess.run wrapper that surfaces the command on unexpected failure.

    Every tool we shell out to signals "duplicates found" with a non-zero exit
    code, so callers pass the codes that mean "ran cleanly for our purposes".
    """
    proc = subprocess.run(
        cmd,
        cwd=cwd or REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode not in ok_codes:
        sys.stderr.write(
            f"{cmd[0]} failed (exit {proc.returncode}):\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {proc.stderr.strip()}\n"
        )
    return proc


# ---------------------------------------------------------------------------
# Tool runners — each returns a list[Clone]
# ---------------------------------------------------------------------------


def run_jscpd(scope_files: list[str] | None) -> list[Clone]:
    """jscpd covers Dart + Shell. Config lives in .jscpd.json."""
    out_dir = REPORT_DIR / "jscpd"
    out_dir.mkdir(parents=True, exist_ok=True)
    json_report = out_dir / "jscpd-report.json"
    if json_report.exists():
        json_report.unlink()

    # Prefer a pre-installed jscpd binary (CI installs jscpd@4.2.5 globally
    # with locked transitive deps). Falling back to `npx --yes -p jscpd@4.2.5`
    # re-resolves dependencies on every invocation; when a compatible
    # commander release goes ESM-only jscpd blows up with ERR_REQUIRE_ESM,
    # silently zeroing out the check.
    jscpd_args = [
        "--silent",
        "--noTips",
        "--config", str(REPO_ROOT / ".jscpd.json"),
    ]
    if shutil.which("jscpd"):
        cmd = ["jscpd", *jscpd_args]
    elif shutil.which("npx"):
        cmd = ["npx", "--yes", "-p", "jscpd@4.2.5", "jscpd", *jscpd_args]
    else:
        sys.stderr.write(
            "jscpd: neither jscpd nor npx found — skipping Dart/Shell detection\n"
        )
        return []
    if scope_files is not None:
        # jscpd needs the whole tree to see cross-file clones — restricting it
        # to a handful of paths silently drops matches against unchanged files.
        # In --changed-only mode we defer Dart/Shell detection to CI and stay
        # fast at pre-commit.
        return []
    cmd.append(str(REPO_ROOT))

    # jscpd exits 0 unless --exitCode>0 is set. Config pins exitCode:0 so
    # anything non-zero is a real failure.
    _run(cmd)

    if not json_report.exists():
        return []

    data = json.loads(json_report.read_text())
    clones: list[Clone] = []
    for entry in data.get("duplicates", []):
        # jscpd reports a pair as one entry with firstFile/secondFile blocks.
        occurrences = []
        for side in ("firstFile", "secondFile"):
            info = entry.get(side, {})
            rel = _relpath(info.get("name", ""))
            if not rel or _excluded(rel):
                occurrences.clear()
                break
            occurrences.append((
                rel,
                int(info.get("start", 0)),
                int(info.get("end", 0)),
            ))
        if len(occurrences) != 2:
            continue

        # Key = hash of (sorted paths, block content). We take the block
        # content from disk rather than trusting jscpd's raw "fragment" — the
        # normalised-whitespace hash lets tiny edits keep matching the
        # baseline, while a real logic change invalidates it.
        occurrences.sort()
        first_rel, first_s, first_e = occurrences[0]
        block = _read_block(first_rel, first_s, first_e)
        key = _hash_block(block)

        for rel, s, e in occurrences:
            clones.append(Clone("jscpd", rel, s, e, key))

    return clones


def run_pylint(scope_files: list[str] | None) -> list[Clone]:
    """pylint's duplicate-code checker for Python."""
    py_files = _python_targets(scope_files)
    if not py_files:
        return []

    if not (shutil.which("pylint") or shutil.which("python3")):
        sys.stderr.write("pylint: not available — skipping Python detection\n")
        return []

    # Pass every option on the CLI instead of via --rcfile. The rcfile path
    # depended on the config being copied into the CI container image, which
    # was not always the case — pylint then bailed with "config file does not
    # exist" and the Python detector silently reported zero clones.
    cmd = [
        "python3", "-m", "pylint",
        "--persistent=no",
        "--jobs=0",
        "--disable=all",
        "--enable=duplicate-code",
        "--score=no",
        "--min-similarity-lines=6",
        "--ignore-comments=yes",
        "--ignore-docstrings=yes",
        "--ignore-imports=yes",
        "--ignore-signatures=yes",
        *py_files,
    ]
    # pylint's exit code is a bitmask: 0=clean, 1=fatal, 2=error, 4=warning,
    # 8=refactor (R0801 lives here), 16=convention, 32=usage. We only care
    # that the process didn't crash, so tolerate 0|8 and any combination of
    # informational bits (up to 30 without the fatal/error/usage bits).
    ok = tuple(code for code in range(0, 32) if not (code & 0b100011))
    proc = _run(cmd, ok_codes=ok)
    return _parse_pylint(proc.stdout)


def _python_targets(scope_files: list[str] | None) -> list[str]:
    if scope_files is None:
        found: list[str] = []
        for base in ("scripts", "hooks"):
            for path in sorted((REPO_ROOT / base).rglob("*.py")):
                rel = _relpath(path)
                if not _excluded(rel):
                    found.append(rel)
        top = REPO_ROOT / "deploy_cron.py"
        if top.exists():
            found.append(_relpath(top))
        return found
    return [f for f in scope_files if f.endswith(".py") and not _excluded(f)]


_PYLINT_DUP_HEADER = re.compile(r"^([\w./-]+):(\d+):\d+: R0801: Similar lines in (\d+) files")
_PYLINT_DUP_LOC = re.compile(r"^==([\w./-]+):\[(\d+):(\d+)\]$")


def _parse_pylint(text: str) -> list[Clone]:
    """Parse pylint's `R0801` duplicate-code output.

    Format (repeated per finding)::

        path/foo.py:1:0: R0801: Similar lines in 2 files
        ==path.to.module:[10:22]
        ==path.to.other:[30:42]
            <block lines...>
    """
    clones: list[Clone] = []
    module_paths = _python_module_index()
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        header = _PYLINT_DUP_HEADER.match(lines[i])
        if not header:
            i += 1
            continue
        i += 1
        occurrences: list[tuple[str, int, int]] = []
        while i < len(lines):
            loc = _PYLINT_DUP_LOC.match(lines[i])
            if not loc:
                break
            module, s, e = loc.group(1), int(loc.group(2)), int(loc.group(3))
            path = module_paths.get(module)
            if not path:
                # Fall back to treating the module as a path if we cannot
                # resolve it (e.g. pylint invoked with a bare filename).
                candidate = REPO_ROOT / f"{module}.py"
                path = _relpath(candidate) if candidate.exists() else module
            occurrences.append((path, s, e))
            i += 1

        # Skip pylint's echoed block body; we re-derive the hash from disk so
        # tweaks to the parser can't shift keys across runs.
        while i < len(lines) and not _PYLINT_DUP_HEADER.match(lines[i]) \
                and not lines[i].startswith("-----"):
            i += 1

        if len(occurrences) < 2:
            continue
        occurrences = [(p, s, e) for p, s, e in occurrences if not _excluded(p)]
        if len(occurrences) < 2:
            continue
        occurrences.sort()
        first_p, first_s, first_e = occurrences[0]
        key = _hash_block(_read_block(first_p, first_s, first_e))
        for path, s, e in occurrences:
            clones.append(Clone("pylint", path, s, e, key))

    return clones


def _python_module_index() -> dict[str, str]:
    """Map pylint module identifiers (dotted, sans .py) to repo-relative paths."""
    idx: dict[str, str] = {}
    for base in ("scripts", "hooks"):
        for path in (REPO_ROOT / base).rglob("*.py"):
            module = path.stem
            idx[module] = _relpath(path)
    top = REPO_ROOT / "deploy_cron.py"
    if top.exists():
        idx[top.stem] = _relpath(top)
    return idx


def run_dupl(scope_files: list[str] | None) -> list[Clone]:
    """dupl for Go — AST-based, uses Go's own parser."""
    if not shutil.which("dupl"):
        sys.stderr.write("dupl: not found on PATH — skipping Go detection\n")
        return []

    go_files = _go_targets(scope_files)
    if not go_files:
        return []

    proc = subprocess.run(
        ["dupl", "-threshold", "50", "-plumbing", *go_files],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return _parse_dupl(proc.stdout)


def _go_targets(scope_files: list[str] | None) -> list[str]:
    # ci/main.go carries an embedded Python patch script that inflates clone
    # counts against itself; exclude it, not the whole ci/ tree.
    excluded_go = {"ci/main.go"}
    if scope_files is None:
        found: list[str] = []
        for base in ("ci", "server"):
            for path in sorted((REPO_ROOT / base).rglob("*.go")):
                rel = _relpath(path)
                if rel in excluded_go or _excluded(rel):
                    continue
                found.append(rel)
        return found
    return [f for f in scope_files
            if f.endswith(".go") and f not in excluded_go and not _excluded(f)]


_DUPL_LINE = re.compile(r"^(\S+?):(\d+)-(\d+): duplicate of (\S+?):(\d+)-(\d+)")


def _parse_dupl(text: str) -> list[Clone]:
    """dupl -plumbing output is `file:start-end: duplicate of file:start-end`."""
    clones: list[Clone] = []
    # dupl emits every pair twice (A→B, B→A). Dedupe by canonical pair identity.
    seen: set[tuple[str, int, int, str, int, int]] = set()
    for line in text.splitlines():
        m = _DUPL_LINE.match(line)
        if not m:
            continue
        a = (_relpath(m.group(1)), int(m.group(2)), int(m.group(3)))
        b = (_relpath(m.group(4)), int(m.group(5)), int(m.group(6)))
        if _excluded(a[0]) or _excluded(b[0]):
            continue
        pair = tuple(sorted([a, b]))
        canonical = (*pair[0], *pair[1])
        if canonical in seen:
            continue
        seen.add(canonical)
        block = _read_block(pair[0][0], pair[0][1], pair[0][2])
        key = _hash_block(block)
        for path, s, e in pair:
            clones.append(Clone("dupl", path, s, e, key))
    return clones


# ---------------------------------------------------------------------------
# Baseline handling
# ---------------------------------------------------------------------------


def load_baseline() -> set[str]:
    if not BASELINE_PATH.exists():
        return set()
    data = json.loads(BASELINE_PATH.read_text())
    return {c["key"] for c in data.get("clones", [])}


def write_baseline(clones: list[Clone]) -> None:
    payload = {
        "$comment": (
            "Auto-generated by scripts/detect_duplication.py. "
            "Re-run `task duplication-baseline` after knowingly accepting new duplicates."
        ),
        "clones": [c.to_dict() for c in sorted(clones)],
    }
    BASELINE_PATH.write_text(json.dumps(payload, indent=2) + "\n")


def format_findings(clones: list[Clone]) -> str:
    if not clones:
        return "no duplicates\n"
    lines = []
    by_key: dict[str, list[Clone]] = {}
    for c in clones:
        by_key.setdefault(c.key, []).append(c)
    for key, occs in sorted(by_key.items()):
        tool = occs[0].tool
        lines.append(f"  [{tool}] {key}")
        for occ in sorted(occs):
            lines.append(f"    - {occ.file}:{occ.start_line}-{occ.end_line}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def _scope_files(changed_only: bool) -> list[str] | None:
    if not changed_only:
        return None
    raw = os.environ.get("DUPLICATION_CHANGED_FILES", "")
    files = [f.strip() for f in raw.splitlines() if f.strip()]
    return [_relpath(f) for f in files]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--baseline", action="store_true",
                      help="Overwrite duplication-baseline.json with current findings.")
    mode.add_argument("--against-baseline", action="store_true",
                      help="Exit non-zero if new clones are found (baseline diff).")
    parser.add_argument("--changed-only", action="store_true",
                        help="Restrict detection to files in DUPLICATION_CHANGED_FILES.")
    args = parser.parse_args(argv)

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    scope = _scope_files(args.changed_only)
    if args.changed_only and not scope:
        print("detect_duplication: no changed files in scope")
        return 0

    # The three detectors are independent subprocesses (jscpd/pylint/dupl) that
    # read the tree and write to separate outputs, so run them concurrently:
    # wall-time drops from their sum toward their slowest. This check dominates
    # CI's warm-cache wall-time (issue #733). Findings are sorted and keyed by
    # content hash downstream, so completion order does not matter; .result()
    # re-raises, so a runner raising (not a tolerated non-zero tool exit, which
    # _run already handles) still aborts the run exactly as the serial loop did.
    clones: list[Clone] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(runner, scope)
                   for runner in (run_jscpd, run_pylint, run_dupl)]
        for future in futures:
            clones.extend(future.result())

    # Persist a full JSON report as a CI artifact regardless of mode.
    (REPORT_DIR / "findings.json").write_text(
        json.dumps({"clones": [c.to_dict() for c in sorted(clones)]}, indent=2)
        + "\n"
    )

    if args.baseline:
        write_baseline(clones)
        print(f"detect_duplication: wrote {len(clones)} occurrences "
              f"({len({c.key for c in clones})} clones) to duplication-baseline.json")
        return 0

    if args.against_baseline:
        baseline_keys = load_baseline()
        new_clones = [c for c in clones if c.key not in baseline_keys]
        if new_clones:
            sys.stderr.write("\nNEW duplicated code detected (not present in baseline):\n\n")
            sys.stderr.write(format_findings(new_clones))
            sys.stderr.write(
                "\nOptions:\n"
                "  1. Refactor the duplicate away (preferred).\n"
                "  2. If the duplication is intentional and unavoidable, "
                "     rerun `task duplication-baseline` and explain the addition "
                "     in your PR description.\n"
            )
            return 1
        print(f"detect_duplication: {len(clones)} known clones, no new duplicates")
        return 0

    print(format_findings(clones))
    return 0


if __name__ == "__main__":
    sys.exit(main())
