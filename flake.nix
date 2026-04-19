{
  description = "SharedInbox — IMAP/SMTP Flutter client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Java JDK — required by Gradle for Android builds
            jdk17

            # Task runner
            go-task

            # Flutter version manager — needed for host builds (task build-linux, task run)
            fvm

            # Local IMAP/SMTP dev server for integration tests
            stalwart-mail

            # Headless display for UI integration tests
            xvfb-run          # wraps Xvfb; xvfb-run --auto-servernum ...

            # Utilities
            git
            curl
            jq
            sqlite
            python3  # used by stalwart-dev/start to pick random ports
          ];

          shellHook = ''
            # Disable Flutter telemetry inside dev shell
            export FLUTTER_SUPPRESS_ANALYTICS=true

            echo "SharedInbox Flutter dev environment ready."
            echo "  Analyze        : task analyze"
            echo "  Unit tests     : task test"
            echo "  Integration    : task integration"
            echo "  All checks     : task check"
            echo "  Run (Linux)    : task run"
            echo "  Start Stalwart : stalwart-dev/start"
          '';
        };
      }
    );
}
