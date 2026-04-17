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
            # libsecret intentionally omitted from Nix inputs: the binary-cache
            # build of libgpg-error (a transitive dep) requires GLIBC_2.42 which
            # is absent on non-NixOS hosts (nixpkgs issue, glibc 2.40 vs 2.42).
            # Use the system package instead:
            #   sudo apt install libsecret-1-dev

            # Local IMAP/SMTP dev server for integration tests
            stalwart-mail

            # Task runner
            go-task

            # Flutter version manager (fvm install downloads the pinned Flutter SDK)
            fvm

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

            # flutter_secure_storage_linux needs libsecret-1 via pkg-config.
            # We use the system package (sudo apt install libsecret-1-dev) because
            # the Nix binary-cache build of libgpg-error (a transitive dep) requires
            # GLIBC_2.42 which is absent in this closure's glibc 2.40.
            export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:''${PKG_CONFIG_PATH:-}"

            # Nix sets TMPDIR/TMP/TEMP to a per-shell dir that is removed when the
            # shell exits. Flutter refuses to start if that dir no longer exists
            # (https://github.com/flutter/flutter/issues/74042). Reset to /tmp.
            export TMPDIR=/tmp
            export TMP=/tmp
            export TEMP=/tmp

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
