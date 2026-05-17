package main

import (
	"context"
	"fmt"
	"dagger/ci/internal/dagger"
)

type Ci struct{}

// Base container with all dependencies for Flutter and Linux builds
func (m *Ci) Base(source *dagger.Directory) *dagger.Container {
	return dag.Container().
		From("ghcr.io/cirruslabs/flutter:3.41.6").
		WithExec([]string{"apt-get", "update"}).
		WithExec([]string{"apt-get", "install", "-y",
			"clang", "cmake", "ninja-build", "pkg-config",
			"libgtk-3-dev", "liblzma-dev", "libsecret-1-dev",
			"libgcrypt20-dev", "libjsoncpp-dev", "sqlite3", "curl", "python3"}).
		WithMountedCache("/root/.pub-cache", dag.CacheVolume("flutter-pub-cache")).
		WithMountedCache("/root/.gradle", dag.CacheVolume("gradle-cache")).
		WithEnvVariable("PUB_CACHE", "/root/.pub-cache").
		WithDirectory("/src", source).
		WithWorkdir("/src")
}

// Setup environment: pub get and build_runner
func (m *Ci) Setup(source *dagger.Directory) *dagger.Container {
	return m.Base(source).
		WithExec([]string{"flutter", "pub", "get"}).
		// Use --delete-conflicting-outputs to ensure generated files match the current source
		WithExec([]string{"flutter", "pub", "run", "build_runner", "build", "--delete-conflicting-outputs"})
}

// Run hygiene check
func (m *Ci) CheckHygiene(ctx context.Context, source *dagger.Directory) (string, error) {
	return m.Base(source).
		WithExec([]string{"/bin/bash", "-c", "FORBIDDEN=\".ssh .bashrc .config .local .cache .gitconfig .android Android .gradle .pub-cache .dartServer .flutter .dart-cli-completion .atuin .bash_logout .profile .zcompdump .zshrc snap .emulator_console_auth_token .lesshst .metadata .tmux.conf\"; for f in $FORBIDDEN; do if [ -e \"$f\" ]; then echo \"ERROR: Forbidden file/dir found in source: $f\"; exit 1; fi; done; echo \"Hygiene check passed.\""}).
		Stdout(ctx)
}

// Enforce architecture — ui/ must not import data/
func (m *Ci) CheckLayers(ctx context.Context, source *dagger.Directory) (string, error) {
	return m.Base(source).
		WithExec([]string{"/bin/bash", "-c", "VIOLATIONS=$(grep -rn \"package:sharedinbox/data/\" lib/ui/ 2>/dev/null || true); if [ -n \"$VIOLATIONS\" ]; then echo \"ERROR: UI layer imports data layer (only core/ interfaces are allowed from ui/):\"; echo \"$VIOLATIONS\"; exit 1; fi; echo \"Layer check passed.\""}).
		Stdout(ctx)
}

// Full check suite (equivalent to task check)
func (m *Ci) Check(ctx context.Context, source *dagger.Directory) (string, error) {
	setup := m.Setup(source)

	// Hygiene & Layers
	if _, err := m.CheckHygiene(ctx, source); err != nil {
		return "Hygiene check failed", err
	}
	if _, err := m.CheckLayers(ctx, source); err != nil {
		return "Layer check failed", err
	}

	// Run analyze
	analyze, err := setup.WithExec([]string{"flutter", "analyze"}).Stdout(ctx)
	if err != nil {
		return analyze, err
	}

	// Run unit tests only (integration tests require Stalwart)
	test, err := setup.WithExec([]string{"flutter", "test", "test/unit"}).Stdout(ctx)
	if err != nil {
		return test, err
	}

	return fmt.Sprintf("All checks passed!\n\nAnalysis:\n%s\n\nTests:\n%s\n", analyze, test), nil
}

// Build and return the Linux bundle
func (m *Ci) BuildLinux(source *dagger.Directory) *dagger.Directory {
	return m.Setup(source).
		WithExec([]string{"flutter", "build", "linux", "--debug"}).
		Directory("build/linux/x64/debug/bundle")
}

// Build and return the Linux bundle (release)
func (m *Ci) BuildLinuxRelease(source *dagger.Directory) *dagger.Directory {
	return m.Setup(source).
		WithExec([]string{"flutter", "build", "linux", "--release"}).
		Directory("build/linux/x64/release/bundle")
}

// Build and return the Android App Bundle (AAB)
func (m *Ci) BuildAndroidRelease(source *dagger.Directory) *dagger.File {
	return m.Setup(source).
		WithExec([]string{"flutter", "build", "appbundle", "--release"}).
		File("build/app/outputs/bundle/release/app-release.aab")
}
