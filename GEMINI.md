# Project Setup & Conventions

## Continuous Integration (CI)
*   **Platform:** Codeberg Actions (Forgejo Actions).
*   **Strategy:** "Thin CI, Heavy Taskfile".
*   **Rule:** CI workflows (`.forgejo/workflows/`) should **never** contain complex logic, dependency installation steps, or custom scripts.
*   **Execution:** CI must only invoke `task` commands (e.g., `nix develop --command task check`). All environment setup is handled by Nix (`flake.nix`), and all task orchestration is handled by `Taskfile.yml`.
*   **Infrastructure:** We use self-hosted runners (`act_runner`) to bypass hosted CI limits and support heavy tasks (like local Stalwart integration tests).

## Code Quality
*   (Add general code quality rules here as they develop)
