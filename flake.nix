{
  description = "SharedInbox — IMAP/SMTP Flutter client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    dagger.url = "github:dagger/nix";
    dagger.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, dagger }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # All Linux desktop runtime libraries needed by flutter build linux and
        # the UI integration tests (xvfb-run).  Kept as a list so we can reuse
        # it for both buildInputs and LD_LIBRARY_PATH / PKG_CONFIG_PATH.
        linuxDesktopLibs = with pkgs; [
          gtk3
          libsecret
          fontconfig
          libepoxy
          mesa
          libGL        # libglvnd — vendor-neutral GL/EGL/GLX dispatch layer
          at-spi2-core
          glib
          pango
          cairo
          gdk-pixbuf
          harfbuzz
        # Dagger remote setup dependencies
        stunnel
        netcat
        ];

        fgj = pkgs.stdenv.mkDerivation {
          pname = "fgj";
          version = "0.4.0";
          src = pkgs.fetchurl {
            url = "https://codeberg.org/romaintb/fgj/releases/download/v0.4.0/fgj_linux_amd64";
            sha256 = "07pia03facvvxq9i1dgl7p47ccv1iqj4drpkp45gvw26d4afkbj7";
          };
          dontUnpack = true;
          installPhase = ''
            mkdir -p $out/bin
            cp $src $out/bin/fgj
            chmod +x $out/bin/fgj
          '';
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Dagger CLI
            dagger.packages.${system}.dagger

            # Go compiler — for Dagger development
            go

            # Java JDK — required by Gradle for Android builds

            # Task runner
            go-task

            # Flutter version manager — needed for host builds (task build-linux, task run)
            fvm

            # Git hooks
            pre-commit

            # Linux desktop build + runtime dependencies (flutter build linux / task run)
          ] ++ linuxDesktopLibs ++ (with pkgs; [
            pkg-config
            clang
            cmake
            ninja

            # Local IMAP/SMTP dev server for integration tests
            stalwart-mail

            # Headless display for UI integration tests
            xvfb-run          # wraps Xvfb; xvfb-run --auto-servernum ...

            # Coverage merging (flutter test --merge-coverage requires lcov)
            lcov

            # Website
            hugo

            # Secrets management (master-key encryption for CI sync)
            age

            # Utilities
            git
            curl
            jq
            sqlite
            # python3 base + Google Play API client (for scripts/deploy_playstore.py)
            (python3.withPackages (ps: with ps; [
              google-api-python-client
              google-auth-httplib2
              httplib2
            ]))  # used by stalwart-dev/start and deploy_playstore.py
            fgj      # Codeberg/Forgejo CLI (like gh for GitHub)
          ]);

          shellHook = ''
            # nix develop --command does not set IN_NIX_SHELL; set it so _preflight passes in CI
            export IN_NIX_SHELL=1

            # Disable Flutter telemetry inside dev shell
            export FLUTTER_SUPPRESS_ANALYTICS=true

            # Expose dev headers to cmake's FindPkgConfig.
            # The nix pkg-config wrapper works in bash but cmake invokes pkg-config
            # as a subprocess and needs PKG_CONFIG_PATH set explicitly.
            export PKG_CONFIG_PATH="${pkgs.gtk3.dev}/lib/pkgconfig:${pkgs.glib.dev}/lib/pkgconfig:${pkgs.pango.dev}/lib/pkgconfig:${pkgs.cairo.dev}/lib/pkgconfig:${pkgs.gdk-pixbuf.dev}/lib/pkgconfig:${pkgs.at-spi2-core.dev}/lib/pkgconfig:${pkgs.harfbuzz.dev}/lib/pkgconfig:${pkgs.libsecret}/lib/pkgconfig:${pkgs.fontconfig.dev}/lib/pkgconfig:${pkgs.libepoxy}/lib/pkgconfig:$PKG_CONFIG_PATH"

            # Nix ld uses --no-copy-dt-needed-entries (strict mode): transitive shared-lib
            # deps are not followed automatically, so link them explicitly.
            export LDFLAGS="-L${pkgs.fontconfig.lib}/lib -lfontconfig $LDFLAGS"

            # Make nix-built runtime libs visible to the dynamic linker so the
            # Flutter Linux bundle and integration-ui tests can run.
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath linuxDesktopLibs}:$LD_LIBRARY_PATH"

            # Wire the libglvnd dispatch to the nix mesa vendor ICDs so GTK/Flutter
            # can create an OpenGL (EGL + GLX) context under Xvfb without a real GPU.
            export __EGL_VENDOR_LIBRARY_DIRS="${pkgs.mesa}/share/glvnd/egl_vendor.d"
            export __GLX_VENDOR_LIBRARY_DIRS="${pkgs.mesa}/lib"
            export LIBGL_ALWAYS_SOFTWARE=1
            export MESA_LOADER_DRIVER_OVERRIDE=softpipe

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
