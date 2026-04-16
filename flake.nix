{
  description = "SharedInbox — IMAP/SMTP Flutter client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, android-nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        };

        androidSdk = android-nixpkgs.sdk.${system} (s: with s; [
          cmdline-tools-latest
          build-tools-35-0-0
          platform-tools
          platforms-android-36
          platforms-android-35
          emulator
        ]);

      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Flutter / Dart toolchain
            flutter

            # Android
            androidSdk

            # Linux desktop build deps (Flutter GTK backend)
            pkg-config
            cmake
            ninja
            clang
            gtk3
            glib
            pcre2
            libepoxy
            at-spi2-atk
            at-spi2-core

            # Local IMAP/SMTP dev server for integration tests
            stalwart-mail

            # Task runner
            go-task

            # Utilities
            git
            curl
            jq
            sqlite
            python3  # used by stalwart-dev/start to pick random ports
          ];

          shellHook = ''
            export ANDROID_HOME="${androidSdk}/share/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

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
