# SharedInbox — Development Guide

## GitHub

We use GitHub: https://github.com/guettli/sharedinbox/

The `gh` CLI is available to query issues/PRs/actions.

## Issue Label Workflow

Automation is handled by [agentloop](https://github.com/guettli/agentloop) running every 5 minutes via cron. Add a label to trigger an agent:

| Label | Trigger | Outcome |
|---|---|---|
| `loop/plan` | Planning agent reads the issue and writes an implementation plan as a comment | Issue moves to `loop/plan-done` |
| `loop/code` | Coding agent implements the change, creates a branch + PR | Issue routes to `loop/merge` |
| `loop/merge` | Merge agent rebases, waits for CI, and merges the PR | Issue moves to `loop/merge-done` |

**State machine:**

```
loop/plan  →  loop/plan-in-process  →  loop/plan-done
                                     ↘  NeedSupervisor  (on failure)

loop/code  →  loop/code-in-process  →  loop/merge (via route)
                                     ↘  NeedSupervisor  (on failure)

loop/merge →  loop/merge-in-process →  loop/merge-done
                                     ↘  NeedSupervisor  (on failure)
```

**Rules:**

- Only issues authored by allowed users are picked up (guettli, guettlibot, guettlibot2, forgejo-actions).
- An issue with `NeedSupervisor` needs human attention — investigate, fix, then re-label.
- The merge agent merges the PR automatically once CI is green. A human still reviews the PR before it merges if branch protection requires a review.
- Planning agents only post a comment — they do NOT write code or open PRs.
- `loop/*` labels are managed by agentloop — do not set them manually while an agent is active.

**Typical lifecycle for a new feature:**

```
1. Create issue
2. Add label loop/plan   → agent writes plan as comment
3. Review plan, request changes or approve
4. Add label loop/code   → agent implements + opens PR + hands off to merge
5. (Optional) Review PR before it merges
6. Merge agent waits for CI and merges the PR automatically
```

## Code conventions

- Avoid `else`, use "early return".

## Drift (DB)

- Schema in `lib/data/db/database.dart`.
- After any schema change run: `dart run build_runner build --delete-conflicting-outputs`
- Generated `database.g.dart` is committed — do not hand-edit it.

## enough_mail

- Standard pub dependency (`enough_mail: ^2.1.7` in `pubspec.yaml`) — not vendored.
- IMAP client helpers are in `lib/data/imap/imap_client_factory.dart`.

## Running

Flutter build dependencies (libgtk-3-dev, libepoxy-dev, libsecret-1-dev, etc.) are installed via apt
— see the Flutter Linux docs. The nix dev shell provides only tools: `task`, `fvm`, `stalwart-mail`.

Enter the nix dev shell first: `nix develop`

```bash
# Code generation (must run after schema changes)
task codegen

# Desktop
task run

# Tests
task test
```

## Adding a screen

1. Create `lib/ui/screens/my_screen.dart`.
2. Add a `GoRoute` in `lib/ui/router.dart`.
3. No separate ViewModel file needed — use `ConsumerWidget` / `ConsumerStatefulWidget` directly with
   Riverpod providers.

## Continuous Integration (CI)

*   **Strategy:** "Thin CI, Heavy Taskfile".
*   **Execution:** CI must only invoke `task` commands (e.g., `nix develop --command task check`).
    All environment setup is handled by Nix (`flake.nix`), and all task orchestration is handled by
    `Taskfile.yml`.
* The cli-tool `fj` is available to query/wait for CI.
