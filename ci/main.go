package main

import (
	"context"
	"fmt"
	"dagger/ci/internal/dagger"
)

type Ci struct{}

// Base container with all dependencies for Flutter and Linux builds
func (m *Ci) Base(source *dagger.Directory) *dagger.Container {
	// Surgical inclusion: only take what is strictly needed for the build/test.
	// This improves caching by ignoring transient or irrelevant files.
	source = source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{
			"lib/",
			"test/",
			"assets/",
			"scripts/",
			"pubspec.yaml",
			"pubspec.lock",
			"analysis_options.yaml",
			"linux/",
			"android/",
			"integration_test/",
			"drift_schemas/",
			"stalwart-dev/",
		},
	})

	return dag.Container().
		From("ghcr.io/cirruslabs/flutter:3.41.6").
		WithExec([]string{"apt-get", "update"}).
		WithExec([]string{"apt-get", "install", "-y",
			"clang", "cmake", "ninja-build", "pkg-config",
			"libgtk-3-dev", "liblzma-dev", "libsecret-1-dev",
			"libgcrypt20-dev", "libjsoncpp-dev", "sqlite3", "curl", "python3", "iproute2"}).
		WithExec([]string{"curl", "-sL", "https://github.com/stalwartlabs/mail-server/releases/download/v0.14.1/stalwart-x86_64-unknown-linux-gnu.tar.gz", "-o", "/tmp/stalwart.tar.gz"}).
		WithExec([]string{"tar", "-xzf", "/tmp/stalwart.tar.gz", "-C", "/usr/local/bin", "stalwart"}).
		WithExec([]string{"chmod", "+x", "/usr/local/bin/stalwart"}).
		WithExec([]string{"rm", "/tmp/stalwart.tar.gz"}).
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

// Run dart format check
func (m *Ci) Format(ctx context.Context, source *dagger.Directory) (string, error) {
	return m.Base(source).
		WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).
		Stdout(ctx)
}

// Verify that mocks are up to date
func (m *Ci) CheckMocks(ctx context.Context, source *dagger.Directory) (string, error) {
	return m.Setup(source).
		WithExec([]string{"git", "init"}).
		WithExec([]string{"git", "config", "user.email", "ci@sharedinbox.de"}).
		WithExec([]string{"git", "config", "user.name", "CI"}).
		WithExec([]string{"git", "add", "."}).
		WithExec([]string{"git", "commit", "-m", "baseline"}).
		WithExec([]string{"flutter", "pub", "run", "build_runner", "build", "--delete-conflicting-outputs"}).
		WithExec([]string{"/bin/bash", "-c", "CHANGED=$(find . -name '*.mocks.dart' | xargs -r git diff --exit-code); if [ $? -ne 0 ]; then echo \"ERROR: Mocks are out of date\"; exit 1; fi; echo \"Mocks are up to date.\""}).
		Stdout(ctx)
}

// Run coverage check
func (m *Ci) Coverage(ctx context.Context, source *dagger.Directory) (string, error) {
	return m.Setup(source).
		WithExec([]string{"flutter", "test", "test/unit", "--coverage"}).
		WithExec([]string{"dart", "scripts/check_coverage.dart"}).
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

	// Format
	if _, err := m.Format(ctx, source); err != nil {
		return "Format check failed", err
	}

	// Run analyze
	analyze, err := setup.WithExec([]string{"flutter", "analyze"}).Stdout(ctx)
	if err != nil {
		return analyze, err
	}

	// Run coverage gate (includes unit tests)
	coverage, err := m.Coverage(ctx, source)
	if err != nil {
		return coverage, err
	}

	// Run backend tests (requires Stalwart)
	testBackend, err := setup.WithExec([]string{"stalwart-dev/test.sh"}).Stdout(ctx)
	if err != nil {
		return testBackend, err
	}

	return fmt.Sprintf("All checks passed!\n\nAnalysis:\n%s\n\n%s\n\nBackend Tests:\n%s\n", analyze, coverage, testBackend), nil
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
