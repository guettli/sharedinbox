{
  description = "SharedInbox — JMAP Compose Multiplatform client";

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

        # Amper is not in nixpkgs — pin the wrapper binary via fetchurl.
        # The wrapper downloads the actual Amper distribution on first run
        # and caches it in ~/.amper (network access required once).
        amper = pkgs.stdenv.mkDerivation {
          name = "amper-0.10.0";
          src = pkgs.fetchurl {
            url = "https://packages.jetbrains.team/maven/p/amper/amper/org/jetbrains/amper/cli/0.10.0/cli-0.10.0-wrapper";
            hash = "sha256-aQKa843X97gJzIP/RFDxKFbB++NmWfMdMezQKEbTBHg=";
          };
          dontUnpack = true;
          installPhase = "install -Dm755 $src $out/bin/amper";
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
            temurin-bin-21   # JDK 21
            androidSdk
            stalwart-mail    # 0.14.1 — local JMAP server for integration tests
            amper
            git
            curl
            jq
          ];

          shellHook = ''
            export ANDROID_HOME="${androidSdk}/share/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export JAVA_HOME="${pkgs.temurin-bin-21}"
            export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

            # Integration test credentials — used when Stalwart is running locally.
            # Two accounts so multi-account sync can be tested.
            export STALWART_URL="http://localhost:8080"
            export STALWART_USER_A="alice"
            export STALWART_PASS_A="secret"
            export STALWART_USER_B="bob"
            export STALWART_PASS_B="secret"

            echo "SharedInbox dev environment ready."
            echo "  Start Stalwart : stalwart-mail --config stalwart-dev/config.toml"
            echo "  Build          : amper build"
            echo "  Test           : amper test"
          '';
        };
      }
    );
}
