# SharedInbox — Development Guide

## Codeberg

We use Codeberg: https://codeberg.org/guettli/sharedinbox/

CLI tool `fgj` is available to query issues/PRs/actions.

## Issue Label Workflow

We use issues, follow this label state machine:

- **State/ToPlan** — Issue needs a plan written by an agent before implementation
- **State/Planned** — Plan has been posted as a comment; awaiting human review
- **State/Ready** — Issue is approved and ready for implementation
- **State/InProgress** — Set while an agent (or human) is actively working
- **State/Question** — Agent hit a blocker or needs clarification

Full lifecycle:

```
State/ToPlan → State/Planned   (automated: agent_loop.py runs a planning agent)
State/Planned → State/Ready    (manual: human reviews the plan and approves)
State/Ready → State/InProgress (automated: agent_loop.py before starting implementation)
State/InProgress → closed      (automated: after PR is merged and CI passes)
any state → State/Question     (automated or manual: when blocked)
```

List open issues ready to pick up:

```bash
fgj issue list --json --state open | jq '[.[] | select(.labels[].name == "State/Ready")] | .[] | {number, title, html_url}'
```

Rules:

- Never start implementation on an issue without `State/Ready`
- Planning agents only post a plan comment — they do NOT write code or open PRs
- After `State/Planned`, a human must review the plan and manually add `State/Ready`
- When working via the agent loop: label transitions are set automatically
  by `agent_loop.py` — do **not** set them yourself.
- When working manually: switch to `State/InProgress` as your **first action**:
  ```bash
  fgj issue edit <NUMBER> --remove-label "State/Ready" --add-label "State/InProgress"
  ```
- If blocked, replace current state label with `State/Question` and leave a comment explaining the blocker
- When done and CI is green, close the issue:
  ```bash
  fgj issue close <NUMBER>
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
* The cli-tool `fgj` is available to query/wait for CI.
