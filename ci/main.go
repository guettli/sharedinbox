package main

import (
	"context"
	"fmt"
	"time"
	"dagger/ci/internal/dagger"
)

type Ci struct {
	// The source directory of the project, filtered surgically.
	Source *dagger.Directory
}

func New(
	// The source directory of the project.
	// +defaultPath=".."
	source *dagger.Directory,
) *Ci {
	return &Ci{
		Source: source.Filter(dagger.DirectoryFilterOpts{
			Include: []string{
				"lib/",
				"test/",
				"assets/",
				"scripts/",
				"pubspec.yaml",
				"analysis_options.yaml",
				"linux/",
				"android/",
				"integration_test/",
				"drift_schemas/",
				"stalwart-dev/",
			},
		}),
	}
}

// Base container with all dependencies for Flutter and Linux builds
func (m *Ci) Base() *dagger.Container {
	return dag.Container().
		From("ghcr.io/cirruslabs/flutter:3.41.6").
		WithExec([]string{"apt-get", "update"}).
		WithExec([]string{"apt-get", "install", "-y", "clang", "cmake", "ninja-build", "pkg-config", "libgtk-3-dev", "liblzma-dev", "libsecret-1-dev", "libgcrypt20-dev", "libjsoncpp-dev", "sqlite3", "curl", "python3", "iproute2", "netcat-openbsd", "xvfb", "libosmesa6", "libgles2-mesa", "libegl1"}).
		WithMountedCache("/root/.pub-cache", dag.CacheVolume("flutter-pub-cache")).
		WithMountedCache("/root/.gradle", dag.CacheVolume("gradle-cache")).
		WithEnvVariable("PUB_CACHE", "/root/.pub-cache").
		WithDirectory("/src", m.Source).
		WithWorkdir("/src")
}

// Hugo container for website builds
func (m *Ci) Hugo() *dagger.Container {
	return dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "--no-cache", "add", "curl", "tar", "libc6-compat", "libstdc++", "gcompat"}).
		WithExec([]string{"curl", "-sL", "https://github.com/gohugoio/hugo/releases/download/v0.152.2/hugo_extended_0.152.2_linux-amd64.tar.gz", "-o", "/tmp/hugo.tar.gz"}).
		WithExec([]string{"tar", "-xzf", "/tmp/hugo.tar.gz", "-C", "/usr/local/bin", "hugo"}).
		WithExec([]string{"rm", "/tmp/hugo.tar.gz"})
}

// Deploy container for rsync/ssh
func (m *Ci) Deployer(sshKey *dagger.Secret) *dagger.Container {
	return dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "--no-cache", "add", "rsync", "openssh-client", "python3", "tar"}).
		WithMountedSecret("/root/.ssh/id_ed25519", sshKey, dagger.ContainerWithMountedSecretOpts{Mode: 0600}).
		WithEnvVariable("RSYNC_RSH", "ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_ed25519")
}

// Latest Stalwart Mail Server as a Dagger Service
func (m *Ci) Stalwart() *dagger.Service {
	config := m.Source.Directory("stalwart-dev").File("config.toml")

	return dag.Container().
		From("stalwartlabs/stalwart:v0.14.1").
		WithFile("/etc/stalwart/config.toml", config).
		// Pre-seed data directory and spam-filter version to avoid network hits on startup.
		WithExec([]string{"/bin/sh", "-c", "mkdir -p /tmp/stalwart && chmod 777 /tmp/stalwart"}).
		WithExec([]string{"sqlite3", "/tmp/stalwart/data.sqlite", "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL); INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');"}).
		WithExposedPort(8080). // JMAP
		WithExposedPort(1430). // IMAP
		WithExposedPort(1025). // SMTP
		WithExposedPort(4190). // ManageSieve
		// Explicitly run the binary with the config path to avoid bootstrap mode.
		WithEntrypoint([]string{"stalwart", "--config", "/etc/stalwart/config.toml"}).
		AsService()
}

// Helper to bind Stalwart service and set up environment variables for tests
func (m *Ci) WithStalwart(container *dagger.Container) *dagger.Container {
	stalwart := m.Stalwart()
	return container.
		WithServiceBinding("stalwart", stalwart).
		WithEnvVariable("STALWART_IMAP_HOST", "stalwart").
		WithEnvVariable("STALWART_SMTP_HOST", "stalwart").
		WithEnvVariable("STALWART_URL", "http://stalwart:8080").
		WithEnvVariable("STALWART_IMAP_PORT", "1430").
		WithEnvVariable("STALWART_SMTP_PORT", "1025").
		WithEnvVariable("STALWART_SIEVE_PORT", "4190").
		WithEnvVariable("STALWART_USER_B", "alice@example.com").
		WithEnvVariable("STALWART_PASS_B", "secret").
		WithEnvVariable("STALWART_USER_C", "bob@example.com").
		WithEnvVariable("STALWART_PASS_C", "secret")
}

// Setup environment: pub get and build_runner
func (m *Ci) Setup() *dagger.Container {
	return m.Base().
		WithExec([]string{"flutter", "pub", "get"}).
		// Use --delete-conflicting-outputs to ensure generated files match the current source
		WithExec([]string{"flutter", "pub", "run", "build_runner", "build", "--delete-conflicting-outputs"})
}

// Run hygiene check
func (m *Ci) CheckHygiene(ctx context.Context) (string, error) {
	return m.Base().
		WithExec([]string{"/bin/bash", "-c", "FORBIDDEN=\".ssh .bashrc .config .local .cache .gitconfig .android Android .gradle .pub-cache .dartServer .flutter .dart-cli-completion .atuin .bash_logout .profile .zcompdump .zshrc snap .emulator_console_auth_token .lesshst .metadata .tmux.conf\"; for f in $FORBIDDEN; do if [ -e \"$f\" ]; then echo \"ERROR: Forbidden file/dir found in source: $f\"; exit 1; fi; done; echo \"Hygiene check passed.\""}).
		Stdout(ctx)
}

// Enforce architecture — ui/ must not import data/
func (m *Ci) CheckLayers(ctx context.Context) (string, error) {
	return m.Base().
		WithExec([]string{"/bin/bash", "-c", "VIOLATIONS=$(grep -rn \"package:sharedinbox/data/\" lib/ui/ 2>/dev/null || true); if [ -n \"$VIOLATIONS\" ]; then echo \"ERROR: UI layer imports data layer (only core/ interfaces are allowed from ui/):\"; echo \"$VIOLATIONS\"; exit 1; fi; echo \"Layer check passed.\""}).
		Stdout(ctx)
}

// Run dart format check
func (m *Ci) Format(ctx context.Context) (string, error) {
	return m.Base().
		WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).
		Stdout(ctx)
}

// Verify that mocks are up to date
func (m *Ci) CheckMocks(ctx context.Context) (string, error) {
	return m.Setup().
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
func (m *Ci) Coverage(ctx context.Context) (string, error) {
	return m.Setup().
		WithExec([]string{"flutter", "test", "test/unit", "--coverage", "--reporter", "expanded"}).
		WithExec([]string{"dart", "scripts/check_coverage.dart"}).
		Stdout(ctx)
}

// Run backend tests (IMAP/JMAP sync logic)
func (m *Ci) TestBackend(ctx context.Context) (string, error) {
	return m.WithStalwart(m.Setup()).
		WithExec([]string{"flutter", "test", "--concurrency=1", "--reporter", "expanded", "test/backend"}).
		Stdout(ctx)
}

// Run UI integration tests via Xvfb
func (m *Ci) TestIntegration(ctx context.Context) (string, error) {
	return m.WithStalwart(m.Setup()).
		// Use xvfb-run for simpler X11 management.
		// LIBGL_ALWAYS_SOFTWARE=1 ensures software rendering for Flutter in headless environments.
		WithEnvVariable("LIBGL_ALWAYS_SOFTWARE", "1").
		WithExec([]string{"xvfb-run", "-s", "-screen 0 1280x720x24", "flutter", "test", "integration_test/", "-d", "linux"}).
		Stdout(ctx)
}

// Run sync reliability runner
func (m *Ci) TestSyncReliability(ctx context.Context) (string, error) {
	return m.WithStalwart(m.Setup()).
		WithExec([]string{"flutter", "test", "test/backend/sync_reliability_test.dart", "--reporter", "expanded", "--concurrency=1"}).
		Stdout(ctx)
}

// Full check suite (equivalent to task check)
func (m *Ci) Check(ctx context.Context) (string, error) {
	// Hygiene & Layers
	if _, err := m.CheckHygiene(ctx); err != nil {
		return "Hygiene check failed", err
	}
	if _, err := m.CheckLayers(ctx); err != nil {
		return "Layer check failed", err
	}

	setup := m.Setup()

	// Format (Running after Setup/pub get ensures package resolution context)
	if _, err := setup.WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).Stdout(ctx); err != nil {
		return "Format check failed", err
	}

	// Run analyze
	analyze, err := setup.WithExec([]string{"flutter", "analyze"}).Stdout(ctx)
	if err != nil {
		return analyze, err
	}

	// Run coverage gate (includes unit tests)
	coverage, err := m.Coverage(ctx)
	if err != nil {
		return coverage, err
	}

	// Run backend tests
	testBackend, err := m.TestBackend(ctx)
	if err != nil {
		return testBackend, err
	}

	// Run UI integration tests
	testIntegration, err := m.TestIntegration(ctx)
	if err != nil {
		return testIntegration, err
	}

	return fmt.Sprintf("All checks passed!\n\nAnalysis:\n%s\n\n%s\n\nBackend Tests:\n%s\n\nIntegration Tests:\n%s\n", analyze, coverage, testBackend, testIntegration), nil
}

// Generate build history Hugo content by scanning the remote server
func (m *Ci) GenerateBuildHistory(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
) *dagger.Directory {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/generate_build_history.py", "website/"},
	})

	return dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"apk", "add", "--no-cache", "openssh-client"}).
		WithMountedSecret("/root/.ssh/id_ed25519", sshKey, dagger.ContainerWithMountedSecretOpts{Mode: 0600}).
		WithEnvVariable("SSH_USER", sshUser).
		WithEnvVariable("SSH_HOST", sshHost).
		WithDirectory("/src", scriptSource).
		WithWorkdir("/src").
		WithExec([]string{"/bin/sh", "-c", "python3 scripts/generate_build_history.py"}).
		Directory("website/content/builds")
}

// Build and return the Hugo-based website bundle
func (m *Ci) BuildWebsite(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
) *dagger.Directory {
	// 1. Generate build history content
	buildHistory := m.GenerateBuildHistory(ctx, sshKey, sshUser, sshHost)

	// 2. Prepare website source (base files + generated history)
	websiteSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"website/"},
	}).WithDirectory("website/content/builds", buildHistory)

	// 3. Build with Hugo
	return m.Hugo().
		WithDirectory("/src", websiteSource).
		WithWorkdir("/src/website").
		WithExec([]string{"hugo", "--minify"}).
		Directory("public")
}

// Build and deploy the website to the remote server
func (m *Ci) PublishWebsite(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
) (string, error) {
	// 1. Build the website
	public := m.BuildWebsite(ctx, sshKey, sshUser, sshHost)

	// 2. Deploy using rsync
	return m.Deployer(sshKey).
		WithDirectory("/public", public).
		WithExec([]string{"rsync", "-avz", "--delete",
			"--exclude=*.apk", "--exclude=*.tar.gz",
			"/public/", fmt.Sprintf("%s@%s:public_html/", sshUser, sshHost)}).
		Stdout(ctx)
}

// Build and return the Linux bundle
func (m *Ci) BuildLinux() *dagger.Directory {
	return m.Setup().
		WithExec([]string{"flutter", "build", "linux", "--release"}).
		Directory("build/linux/x64/release/bundle")
}

// Build and return the Linux bundle (release)
func (m *Ci) BuildLinuxRelease() *dagger.Directory {
	return m.Setup().
		WithExec([]string{"flutter", "build", "linux", "--release"}).
		Directory("build/linux/x64/release/bundle")
}

// Package and deploy the Linux release to the server
func (m *Ci) DeployLinux(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
) (string, error) {
	// 1. Build the release bundle
	bundle := m.BuildLinuxRelease()

	// 2. Package and deploy
	datePath := time.Now().Format("2006/01/02")
	remoteDir := fmt.Sprintf("public_html/builds/%s", datePath)
	tarball := fmt.Sprintf("sharedinbox-linux-amd64-%s.tar.gz", commitHash)

	return m.Deployer(sshKey).
		WithDirectory("/bundle", bundle).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("tar -czf /tmp/%s -C /bundle .", tarball)}).
		WithExec([]string{"ssh", "-o", "StrictHostKeyChecking=no", "-i", "/root/.ssh/id_ed25519", fmt.Sprintf("%s@%s", sshUser, sshHost), fmt.Sprintf("mkdir -p %s", remoteDir)}).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("scp -o StrictHostKeyChecking=no -i /root/.ssh/id_ed25519 /tmp/%s %s@%s:%s/%s", tarball, sshUser, sshHost, remoteDir, tarball)}).
		Stdout(ctx)
}

// Build and return the Android APK
func (m *Ci) BuildAndroidApk() *dagger.File {
	return m.Setup().
		WithExec([]string{"flutter", "build", "apk", "--release"}).
		File("build/app/outputs/flutter-apk/app-release.apk")
}

// Deploy the Android APK to the server
func (m *Ci) DeployApk(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
) (string, error) {
	// 1. Build the APK
	apk := m.BuildAndroidApk()

	// 2. Deploy
	datePath := time.Now().Format("2006/01/02")
	remoteDir := fmt.Sprintf("public_html/builds/%s", datePath)
	apkName := fmt.Sprintf("sharedinbox-mua-%s.apk", commitHash)

	return m.Deployer(sshKey).
		WithFile("/tmp/app.apk", apk).
		WithExec([]string{"ssh", "-o", "StrictHostKeyChecking=no", "-i", "/root/.ssh/id_ed25519", fmt.Sprintf("%s@%s", sshUser, sshHost), fmt.Sprintf("mkdir -p %s", remoteDir)}).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("scp -o StrictHostKeyChecking=no -i /root/.ssh/id_ed25519 /tmp/app.apk %s@%s:%s/%s", sshUser, sshHost, remoteDir, apkName)}).
		Stdout(ctx)
}

// Build and return the Android App Bundle (AAB)
func (m *Ci) BuildAndroidRelease() *dagger.File {
	return m.Setup().
		WithExec([]string{"flutter", "build", "appbundle", "--release"}).
		File("build/app/outputs/bundle/release/app-release.aab")
}

// Publish the Android App Bundle to Google Play Store
func (m *Ci) PublishAndroid(
	ctx context.Context,
	playStoreConfig *dagger.Secret,
) (string, error) {
	// 1. Build the AAB
	aab := m.BuildAndroidRelease()

	// 2. Prepare script source
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/deploy_playstore.py"},
	})

	// 3. Deploy
	return dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"apk", "add", "--no-cache", "curl"}).
		WithExec([]string{"pip", "install", "requests", "google-auth"}).
		WithFile("/src/build/app/outputs/bundle/release/app-release.aab", aab).
		WithFile("/src/scripts/deploy_playstore.py", scriptSource.File("scripts/deploy_playstore.py")).
		WithSecretVariable("PLAY_STORE_CONFIG_JSON", playStoreConfig).
		WithWorkdir("/src").
		WithExec([]string{"python3", "scripts/deploy_playstore.py"}).
		Stdout(ctx)
}
