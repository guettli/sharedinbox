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
            stalwart-mail    # 0.14.1 — local JMAP server for integration tests (binary: stalwart)
            amper
            go-task          # task runner (Taskfile.yml)
            ktlint           # Kotlin linter / formatter
            git
            curl
            jq
            # OpenGL + X11 + C++ runtime — required by Skiko (Compose Desktop renderer) on Linux
            libGL
            libGLU
            mesa      # DRI drivers incl. software rasterizer (swrast_dri.so)
            stdenv.cc.cc.lib  # libstdc++.so.6
            xorg.libX11
            xorg.libXext
            xorg.libXrandr
            xorg.libXi
            xorg.libXrender
            xorg.libXxf86vm
            xorg.libXcursor
          ];

          shellHook = ''
            # Skiko (Compose Desktop renderer) needs OpenGL + X11 + C++ runtime at runtime.
            export LD_LIBRARY_PATH="${pkgs.libGL}/lib:${pkgs.libGLU}/lib:${pkgs.mesa}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.xorg.libX11}/lib:${pkgs.xorg.libXext}/lib:${pkgs.xorg.libXrandr}/lib:${pkgs.xorg.libXi}/lib:${pkgs.xorg.libXrender}/lib:${pkgs.xorg.libXxf86vm}/lib:${pkgs.xorg.libXcursor}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri"
            # Fall back to Mesa software rasterizer when no GPU is available (CI, VMs, headless).
            export SKIKO_RENDER_API=SOFTWARE

            export ANDROID_HOME="${androidSdk}/share/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export JAVA_HOME="${pkgs.temurin-bin-21}"
            export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

            # Assign a random Stalwart port the first time this repo is entered, and persist it
            # in .env so it stays stable across sessions. Using a high port (50000-59999) avoids
            # conflicts with system services. When the same repo is cloned twice, each clone gets
            # its own port, so both can run Stalwart and the integration tests simultaneously.
            # Assign a random Stalwart port the first time this repo is entered, and persist it
            # in .env so it stays stable across sessions. Using a high port (50000-59999) avoids
            # conflicts with system services. When the same repo is cloned twice, each clone gets
            # its own port, so both can run Stalwart and the integration tests simultaneously.
            if ! grep -qs '^STALWART_PORT=' .env 2>/dev/null; then
              _port=$(( RANDOM % 10000 + 50000 ))
              printf '# Per-clone Stalwart port — avoids conflicts when the repo is cloned more than once\n# on the same machine. Chosen on first "nix develop". Delete to regenerate.\nSTALWART_PORT=%s\n' "$_port" >> .env
            fi
            export STALWART_PORT=$(grep '^STALWART_PORT=' .env | cut -d= -f2)
            export STALWART_URL="http://localhost:$STALWART_PORT"
            export STALWART_USER_A="admin"
            export STALWART_PASS_A="admin"
            export STALWART_USER_B="alice"
            export STALWART_PASS_B="secret"
            export STALWART_USER_C="bob"
            export STALWART_PASS_C="secret"

            echo "SharedInbox dev environment ready (Stalwart port: $STALWART_PORT)."
            echo "  Check (fast)   : task check"
            echo "  Check (full)   : task check-full"
            echo "  Start Stalwart : stalwart-dev/start"
            echo "  Build          : amper build"
          '';
        };
      }
    );
}
