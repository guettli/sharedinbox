package main

import (
	"context"
	"dagger/ci/internal/dagger"
	"fmt"
	"time"

	"golang.org/x/sync/errgroup"
)

// patchAabScript patches android:versionCode in an AAB's compiled manifest proto.
// It strips META-INF/ (old signature) and repacks the ZIP. No external dependencies.
const patchAabScript = `#!/usr/bin/env python3
import sys, zipfile

MANIFEST = "base/manifest/AndroidManifest.xml"
VERSION_CODE_RID = 0x0101021b

def _vr(b, p):
    n = s = 0
    while True:
        c = b[p]; p += 1; n |= (c & 127) << s
        if not (c & 128): return n, p
        s += 7

def _ve(n):
    r = []
    while n > 127: r.append((n & 127) | 128); n >>= 7
    return bytes(r + [n])

def _parse(d):
    p = 0
    while p < len(d):
        tag, p = _vr(d, p); fn, wt = tag >> 3, tag & 7
        if wt == 0: v, p = _vr(d, p); yield fn, 0, v
        elif wt == 2: ln, p = _vr(d, p); yield fn, 2, d[p:p+ln]; p += ln
        elif wt == 5: yield fn, 5, d[p:p+4]; p += 4  # fixed32
        elif wt == 1: yield fn, 1, d[p:p+8]; p += 8  # fixed64
        else: raise ValueError(f"wire type {wt}")

def _enc(fn, wt, v):
    t = _ve((fn << 3) | wt)
    if wt == 0: return t + _ve(v)
    if wt in (1, 5): return t + v  # fixed-width, pass bytes as-is
    return t + _ve(len(v)) + v

def _patch_prim(d, vc):
    # Patch int_decimal_value (field 6) or int_hexadecimal_value (field 7),
    # whichever is present — AAPT2 may use either.
    out = bytearray()
    for fn, wt, v in _parse(d):
        out += _enc(fn, 0, vc) if (fn in (6, 7) and wt == 0) else _enc(fn, wt, v)
    return bytes(out)

def _patch_item(d, vc):
    out = bytearray()
    for fn, wt, v in _parse(d):
        out += _enc(7, 2, _patch_prim(v, vc)) if fn == 7 else _enc(fn, wt, v)
    return bytes(out)

def _has_rid(d):
    return any(fn == 5 and wt == 0 and v == VERSION_CODE_RID for fn, wt, v in _parse(d))

def _patch_attr(d, vc):
    out = bytearray()
    for fn, wt, v in _parse(d):
        if fn == 3 and wt == 2: out += _enc(3, 2, str(vc).encode())
        elif fn == 6 and wt == 2: out += _enc(6, 2, _patch_item(v, vc))
        else: out += _enc(fn, wt, v)
    return bytes(out)

def _patch_elem(d, vc):
    out = bytearray()
    for fn, wt, v in _parse(d):
        out += _enc(4, 2, _patch_attr(v, vc)) if (fn == 4 and _has_rid(v)) else _enc(fn, wt, v)
    return bytes(out)

def _patch_node(d, vc):
    out = bytearray()
    for fn, wt, v in _parse(d):
        out += _enc(1, 2, _patch_elem(v, vc)) if fn == 1 else _enc(fn, wt, v)
    return bytes(out)

def _dump_proto(d, depth=0, limit=3):
    """Print proto field structure for debugging."""
    pad = "  " * depth
    for fn, wt, v in _parse(d):
        if wt == 0:
            print(f"{pad}[{fn}] varint={v} (0x{v:x})")
        elif wt == 2:
            print(f"{pad}[{fn}] bytes len={len(v)}")
            if depth < limit:
                _dump_proto(v, depth + 1, limit)
        elif wt == 5:
            print(f"{pad}[{fn}] fixed32={v.hex()}")
        elif wt == 1:
            print(f"{pad}[{fn}] fixed64={v.hex()}")

def _read_vc_from_node(d):
    """Read versionCode from XmlNode proto bytes. Returns int or None."""
    for fn, wt, v in _parse(d):
        if fn == 1 and wt == 2:  # XmlElement
            for efn, ewt, attr in _parse(v):
                if efn == 4 and ewt == 2 and _has_rid(attr):  # XmlAttribute with versionCode RID
                    for afn, awt, item in _parse(attr):
                        if afn == 6 and awt == 2:  # compiled_value (Item)
                            for ifn, iwt, prim in _parse(item):
                                if ifn == 7 and iwt == 2:  # prim (Primitive)
                                    for pfn, pwt, pv in _parse(prim):
                                        if pfn in (6, 7) and pwt == 0:
                                            return pv
    return None

def patch(src, dst, vc):
    with zipfile.ZipFile(src) as z:
        mf = z.read(MANIFEST)

    orig_vc = _read_vc_from_node(mf)
    if orig_vc is None:
        print("DEBUG: could not find versionCode — dumping manifest proto structure:")
        _dump_proto(mf, limit=4)
        sys.exit(f"ERROR: versionCode not found in {MANIFEST}")
    print(f"Original versionCode in manifest: {orig_vc}")

    patched = _patch_node(mf, vc)
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w') as zout:
        for info in zin.infolist():
            if info.filename.startswith('META-INF/'):
                continue  # strip old signature; jarsigner re-signs after
            d = patched if info.filename == MANIFEST else zin.read(info.filename)
            zi = zipfile.ZipInfo(info.filename, info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zout.writestr(zi, d)

    # Verify the patch actually took effect
    with zipfile.ZipFile(dst) as z:
        actual = _read_vc_from_node(z.read(MANIFEST))
    if actual != vc:
        sys.exit(f"ERROR: versionCode patch failed — wrote {vc} but read back {actual} (original was {orig_vc})")
    print(f"versionCode={actual} -> {dst}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} in.aab out.aab versionCode")
    patch(sys.argv[1], sys.argv[2], int(sys.argv[3]))
`

type Ci struct {
	Source *dagger.Directory
}

func New(
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
				"pubspec.lock",
				"analysis_options.yaml",
				"linux/",
				"android/",
				"integration_test/",
				"drift_schemas/",
				"stalwart-dev/",
				"website/",
			},
		}),
	}
}

// toolchain returns the Flutter+Android toolchain without any mutable cache mounts.
// Its execution cache key is stable until the image, apt packages, or SDK versions change.
// Used as the base for pubGetLayer so flutter pub get is execution-cached between runs.
func (m *Ci) toolchain() *dagger.Container {
	return dag.Container().
		From("ghcr.io/cirruslabs/flutter:3.41.6").
		WithExec([]string{"apt-get", "-qq", "update"}).
		WithExec([]string{"apt-get", "install", "-y", "-qq", "clang", "cmake", "ninja-build", "pkg-config", "libgtk-3-dev", "liblzma-dev", "libsecret-1-dev", "libgcrypt20-dev", "libjsoncpp-dev", "sqlite3", "iproute2", "netcat-openbsd", "xvfb", "libosmesa6", "libegl1", "lld"}).
		WithExec([]string{"useradd", "-m", "-s", "/bin/bash", "ci"}).
		WithExec([]string{"/bin/sh", "-c",
			`flutter_dir=$(dirname $(dirname $(which flutter))); ` +
				`chown -R ci:ci "$flutter_dir"; ` +
				`[ -n "$ANDROID_HOME" ] && chown -R ci:ci "$ANDROID_HOME" || true; ` +
				`mkdir -p /src && chown ci:ci /src`}).
		WithEnvVariable("PUB_CACHE", "/home/ci/.pub-cache").
		WithEnvVariable("HOME", "/home/ci").
		WithUser("ci").
		WithExec([]string{"/bin/sh", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`yes | sdkmanager "ndk;28.2.13676358" "cmake;3.22.1" "build-tools;35.0.0" "platforms;android-34" >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }`})
}

// Base is the Flutter toolchain container with mutable cache mounts attached.
// Use for Android/Gradle builds that need the pub and Gradle caches.
// Do NOT use as the base for pubGetLayer — the mutable pub cache volume makes
// flutter pub get's execution cache key unstable, causing a cache miss every run.
func (m *Ci) Base() *dagger.Container {
	return m.toolchain().
		WithMountedCache("/home/ci/.pub-cache", dag.CacheVolume("flutter-pub-cache"), dagger.ContainerWithMountedCacheOpts{Owner: "ci"}).
		WithMountedCache("/home/ci/.gradle", dag.CacheVolume("gradle-cache"), dagger.ContainerWithMountedCacheOpts{Owner: "ci"})
}

// pubGetLayer runs flutter pub get with only pubspec.yaml + pubspec.lock as
// inputs, then removes non-deterministic fields from both package_config.json
// and .flutter-plugins-dependencies so the snapshot is byte-for-byte stable
// across runs. Re-executes only when pubspec.yaml or pubspec.lock changes.
// Uses toolchain() (no pub cache volume) so Dagger's execution cache is stable.
func (m *Ci) pubGetLayer() *dagger.Container {
	pubspecOnly := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"pubspec.yaml", "pubspec.lock"},
	})
	return m.toolchain().
		WithMountedCache("/home/ci/.gradle", dag.CacheVolume("gradle-cache"), dagger.ContainerWithMountedCacheOpts{Owner: "ci"}).
		WithDirectory("/src", pubspecOnly, dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter pub get >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -vE '^[+~><] ' "$tmp" || true`}).
		WithExec([]string{"python3", "-c",
			"import json, os\n" +
				"f='.dart_tool/package_config.json'; d=json.load(open(f)); [d.pop(k,None) for k in ('generated','generatorVersion')]; json.dump(d,open(f,'w'))\n" +
				"g='.flutter-plugins-dependencies'\n" +
				"if os.path.exists(g):\n" +
				"  d=json.load(open(g)); d.pop('date_created',None); json.dump(d,open(g,'w'))\n"})
}

// codegenBase runs build_runner on the source subset common to all build
// variants (lib/, test/, assets/, pubspec.*), excluding committed generated
// files so the cache key is stable. All setup() calls share this single
// Dagger cache entry, so build_runner compiles only once per pipeline run.
func (m *Ci) codegenBase() *dagger.Container {
	codegenSrc := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "test/", "assets/", "pubspec.yaml", "pubspec.lock"},
		Exclude: []string{"**/*.g.dart", "**/*.mocks.dart"},
	})
	return m.pubGetLayer().
		WithDirectory("/src", codegenSrc, dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter pub run build_runner build --delete-conflicting-outputs >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -vE '^\[' "$tmp" || true`})
}

// setup overlays platform-specific source files onto the shared codegen base.
// Generated files (*.g.dart, *.mocks.dart) are excluded from the overlay so
// the freshly built output from codegenBase() is not overwritten by stale
// committed copies.
func (m *Ci) setup(src *dagger.Directory) *dagger.Container {
	return m.codegenBase().
		WithDirectory("/src", src.Filter(dagger.DirectoryFilterOpts{
			Exclude: []string{"**/*.g.dart", "**/*.mocks.dart"},
		}), dagger.ContainerWithDirectoryOpts{Owner: "ci"})
}

// Setup is the exported variant (CLI / Taskfile). Uses the full check source.
func (m *Ci) Setup() *dagger.Container {
	return m.setup(m.checkSrc())
}

// checkSrc is the source subset for static checks and unit tests.
func (m *Ci) checkSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "test/", "assets/", "pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "scripts/"},
	})
}

// androidSrc is the source subset for Android builds.
func (m *Ci) androidSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "android/", "assets/", "pubspec.yaml", "pubspec.lock", "drift_schemas/"},
	})
}

// firebaseSrc is the source subset for Firebase Test Lab builds (app + instrumented tests).
func (m *Ci) firebaseSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "android/", "integration_test/", "assets/", "pubspec.yaml", "pubspec.lock", "drift_schemas/"},
	})
}

// linuxSrc is the source subset for Linux builds and integration tests.
func (m *Ci) linuxSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "linux/", "assets/", "pubspec.yaml", "pubspec.lock", "drift_schemas/"},
	})
}

// backendSrc is the source subset for IMAP/JMAP backend tests.
func (m *Ci) backendSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "test/", "assets/", "scripts/", "stalwart-dev/", "pubspec.yaml", "pubspec.lock"},
	})
}

// integrationSrc is the source subset for UI integration tests (runs on Linux desktop).
func (m *Ci) integrationSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"lib/", "linux/", "integration_test/", "assets/", "pubspec.yaml", "pubspec.lock", "drift_schemas/"},
	})
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

// Stalwart mail server service for backend and integration tests.
func (m *Ci) Stalwart() *dagger.Service {
	stalwartSrc := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"stalwart-dev/"},
	})
	config := stalwartSrc.Directory("stalwart-dev").File("config.toml")

	dataDir := dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "add", "--no-cache", "sqlite"}).
		WithExec([]string{"/bin/sh", "-c", "mkdir -p /tmp/stalwart && chmod 777 /tmp/stalwart"}).
		WithExec([]string{"sqlite3", "/tmp/stalwart/data.sqlite", "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL); INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');"}).
		Directory("/tmp/stalwart")

	return dag.Container().
		From("stalwartlabs/stalwart:v0.14.1").
		WithFile("/etc/stalwart/config.toml.orig", config).
		WithExec([]string{"/bin/sh", "-c", "sed -e 's/hostname = \"localhost\"/hostname = \"stalwart\"/' -e 's/bind     = \\[\"0.0.0.0:\\([0-9]*\\)\"\\]/bind     = [\"0.0.0.0:\\1\", \"[::]:\\1\"]/g' /etc/stalwart/config.toml.orig > /etc/stalwart/config.toml"}).
		WithDirectory("/tmp/stalwart", dataDir).
		WithExposedPort(8080). // JMAP
		WithExposedPort(1430). // IMAP
		WithExposedPort(1025). // SMTP
		WithExposedPort(4190). // ManageSieve
		WithEntrypoint([]string{"stalwart", "--config", "/etc/stalwart/config.toml"}).
		AsService()
}

// WithStalwart binds the Stalwart service and sets test environment variables.
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

// CheckHygiene checks that no forbidden home-directory files are in the source.
func (m *Ci) CheckHygiene(ctx context.Context) (string, error) {
	return m.Base().
		WithDirectory("/src", m.Source, dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c", "FORBIDDEN=\".ssh .bashrc .config .local .cache .gitconfig .android Android .gradle .pub-cache .dartServer .flutter .dart-cli-completion .atuin .bash_logout .profile .zcompdump .zshrc snap .emulator_console_auth_token .lesshst .metadata .tmux.conf\"; for f in $FORBIDDEN; do if [ -e \"$f\" ]; then echo \"ERROR: Forbidden file/dir found in source: $f\"; exit 1; fi; done; echo \"Hygiene check passed.\""}).
		Stdout(ctx)
}

// CheckLayers enforces that ui/ does not import data/.
func (m *Ci) CheckLayers(ctx context.Context) (string, error) {
	return m.Base().
		WithDirectory("/src", m.Source.Filter(dagger.DirectoryFilterOpts{Include: []string{"lib/"}}), dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c", "VIOLATIONS=$(grep -rn \"package:sharedinbox/data/\" lib/ui/ 2>/dev/null || true); if [ -n \"$VIOLATIONS\" ]; then echo \"ERROR: UI layer imports data layer (only core/ interfaces are allowed from ui/):\"; echo \"$VIOLATIONS\"; exit 1; fi; echo \"Layer check passed.\""}).
		Stdout(ctx)
}

// Format runs dart format check.
func (m *Ci) Format(ctx context.Context) (string, error) {
	return m.setup(m.checkSrc()).
		WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).
		Stdout(ctx)
}

// CheckMocks verifies that generated mocks are up to date.
// It snapshots the committed source (including any stale *.mocks.dart) before
// running build_runner, so git diff detects real staleness instead of always
// comparing two freshly-generated outputs.
func (m *Ci) CheckMocks(ctx context.Context) (string, error) {
	return m.pubGetLayer().
		WithDirectory("/src", m.checkSrc(), dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"git", "init"}).
		WithExec([]string{"git", "config", "user.email", "ci@sharedinbox.de"}).
		WithExec([]string{"git", "config", "user.name", "CI"}).
		WithExec([]string{"git", "add", "."}).
		WithExec([]string{"git", "commit", "-q", "-m", "baseline"}).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter pub run build_runner build --delete-conflicting-outputs >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -vE '^\[' "$tmp" || true`}).
		WithExec([]string{"/bin/bash", "-c", "CHANGED=$(find . -name '*.mocks.dart' | xargs -r git diff --exit-code); if [ $? -ne 0 ]; then echo \"ERROR: Mocks are out of date\"; exit 1; fi; echo \"Mocks are up to date.\""}).
		Stdout(ctx)
}

// Coverage runs unit tests with coverage gate.
func (m *Ci) Coverage(ctx context.Context) (string, error) {
	return m.setup(m.checkSrc()).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter test test/unit --coverage --reporter expanded --no-pub >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -E '^All [0-9]+ tests passed' "$tmp" || tail -1 "$tmp"`}).
		WithExec([]string{"dart", "scripts/check_coverage.dart"}).
		Stdout(ctx)
}

// TestBackend runs IMAP/JMAP sync tests against a live Stalwart instance.
func (m *Ci) TestBackend(ctx context.Context) (string, error) {
	return m.WithStalwart(m.setup(m.backendSrc())).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter test --concurrency=1 --reporter expanded --no-pub test/backend >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -E '^All [0-9]+ tests passed' "$tmp" || tail -1 "$tmp"`}).
		Stdout(ctx)
}

// TestIntegration runs UI integration tests via Xvfb.
func (m *Ci) TestIntegration(ctx context.Context) (string, error) {
	return m.WithStalwart(m.setup(m.integrationSrc())).
		WithEnvVariable("LIBGL_ALWAYS_SOFTWARE", "1").
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`xvfb-run -s '-screen 0 1280x720x24' flutter test integration_test/ -d linux >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -E '^All [0-9]+ tests passed' "$tmp" || tail -1 "$tmp"`}).
		Stdout(ctx)
}

// TestSyncReliability runs the sync reliability runner.
func (m *Ci) TestSyncReliability(ctx context.Context) (string, error) {
	return m.WithStalwart(m.setup(m.backendSrc())).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter test test/backend/sync_reliability_test.dart --reporter expanded --concurrency=1 --no-pub >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -E '^All [0-9]+ tests passed' "$tmp" || tail -1 "$tmp"`}).
		Stdout(ctx)
}

// Check runs the full check suite.
func (m *Ci) Check(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	if _, err := m.CheckHygiene(ctx); err != nil {
		return "Hygiene check failed", err
	}
	if _, err := m.CheckLayers(ctx); err != nil {
		return "Layer check failed", err
	}

	checkSetup := m.setup(m.checkSrc())

	if _, err := checkSetup.WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).Stdout(ctx); err != nil {
		return "Format check failed", err
	}

	analyze, err := checkSetup.WithExec([]string{"dart", "analyze", "--fatal-infos"}).Stdout(ctx)
	if err != nil {
		return analyze, err
	}

	mocks, err := m.CheckMocks(ctx)
	if err != nil {
		return mocks, err
	}

	coverage, err := m.Coverage(ctx)
	if err != nil {
		return coverage, err
	}

	var testBackend, testIntegration string
	eg, egCtx := errgroup.WithContext(ctx)
	eg.Go(func() error {
		var e error
		testBackend, e = m.TestBackend(egCtx)
		return e
	})
	eg.Go(func() error {
		var e error
		testIntegration, e = m.TestIntegration(egCtx)
		return e
	})
	if err := eg.Wait(); err != nil {
		return "", err
	}

	return fmt.Sprintf("All checks passed!\n\nAnalysis:\n%s\n\n%s\n\n%s\n\nBackend Tests:\n%s\n\nIntegration Tests:\n%s\n", analyze, mocks, coverage, testBackend, testIntegration), nil
}

// GenerateBuildHistory scans the remote server and produces Hugo content.
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

// BuildWebsite builds the Hugo-based website.
func (m *Ci) BuildWebsite(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
) *dagger.Directory {
	buildHistory := m.GenerateBuildHistory(ctx, sshKey, sshUser, sshHost)

	websiteSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"website/"},
	}).WithDirectory("website/content/builds", buildHistory)

	return m.Hugo().
		WithDirectory("/src", websiteSource).
		WithWorkdir("/src/website").
		WithExec([]string{"hugo", "--minify"}).
		Directory("public")
}

// PublishWebsite builds and deploys the website to the remote server.
func (m *Ci) PublishWebsite(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
) (string, error) {
	public := m.BuildWebsite(ctx, sshKey, sshUser, sshHost)

	return m.Deployer(sshKey).
		WithDirectory("/public", public).
		WithExec([]string{"rsync", "-avz", "--delete",
			"--exclude=*.apk", "--exclude=*.tar.gz",
			"/public/", fmt.Sprintf("%s@%s:public_html/", sshUser, sshHost)}).
		Stdout(ctx)
}

// BuildLinux builds the Linux release bundle.
func (m *Ci) BuildLinux() *dagger.Directory {
	return m.setup(m.linuxSrc()).
		WithExec([]string{"flutter", "build", "linux", "--release"}).
		Directory("build/linux/x64/release/bundle")
}

// BuildLinuxRelease builds the Linux release bundle.
func (m *Ci) BuildLinuxRelease() *dagger.Directory {
	return m.setup(m.linuxSrc()).
		WithExec([]string{"flutter", "build", "linux", "--release"}).
		Directory("build/linux/x64/release/bundle")
}

// DeployLinux packages and deploys the Linux release to the server.
func (m *Ci) DeployLinux(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
) (string, error) {
	bundle := m.BuildLinuxRelease()

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

// setupKeystore decodes the base64 keystore into the android build container.
func (m *Ci) setupKeystore(keystoreBase64 *dagger.Secret, keystorePassword *dagger.Secret) *dagger.Container {
	return m.setup(m.androidSrc()).
		WithSecretVariable("ANDROID_KEYSTORE_BASE64", keystoreBase64).
		WithSecretVariable("ANDROID_KEYSTORE_PASSWORD", keystorePassword).
		WithExec([]string{"/bin/sh", "-c", `echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/app/upload-keystore.jks`})
}

// BuildAndroidApk builds a release APK signed with the upload key.
func (m *Ci) BuildAndroidApk(keystoreBase64 *dagger.Secret, keystorePassword *dagger.Secret, buildNumber string) *dagger.File {
	return m.setupKeystore(keystoreBase64, keystorePassword).
		WithExec([]string{"flutter", "build", "apk", "--release", "--no-pub", "--build-number", buildNumber}).
		File("build/app/outputs/flutter-apk/app-release.apk")
}

// DeployApk builds and deploys the APK to the server.
func (m *Ci) DeployApk(
	ctx context.Context,
	sshKey *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
	keystoreBase64 *dagger.Secret,
	keystorePassword *dagger.Secret,
	buildNumber string,
) (string, error) {
	apk := m.BuildAndroidApk(keystoreBase64, keystorePassword, buildNumber)

	datePath := time.Now().Format("2006/01/02")
	remoteDir := fmt.Sprintf("public_html/builds/%s", datePath)
	apkName := fmt.Sprintf("sharedinbox-mua-%s.apk", commitHash)

	return m.Deployer(sshKey).
		WithFile("/tmp/app.apk", apk).
		WithExec([]string{"ssh", "-o", "StrictHostKeyChecking=no", "-i", "/root/.ssh/id_ed25519", fmt.Sprintf("%s@%s", sshUser, sshHost), fmt.Sprintf("mkdir -p %s", remoteDir)}).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("scp -o StrictHostKeyChecking=no -i /root/.ssh/id_ed25519 /tmp/app.apk %s@%s:%s/%s", sshUser, sshHost, remoteDir, apkName)}).
		Stdout(ctx)
}

// BuildAndroidDebugApks builds the debug app APK and the androidTest APK needed for Firebase Test Lab.
// Returns a flat directory with app-debug.apk and app-debug-androidTest.apk.
func (m *Ci) BuildAndroidDebugApks() *dagger.Directory {
	built := m.setup(m.firebaseSrc()).
		WithExec([]string{"flutter", "build", "apk", "--debug", "--no-pub"}).
		WithWorkdir("/src/android").
		WithExec([]string{"./gradlew", "app:assembleAndroidTest"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c",
			`apk=$(find /src -path "*androidTest*" -name "*.apk" -type f 2>/dev/null | head -1) && \
			 [ -n "$apk" ] || { echo "ERROR: no androidTest APK found; APKs present:"; find /src -name "*.apk" -type f 2>/dev/null; exit 1; } && \
			 echo "Found test APK: $apk" && \
			 cp "$apk" /src/app-debug-androidTest.apk`})

	return dag.Directory().
		WithFile("app-debug.apk",
			built.File("build/app/outputs/flutter-apk/app-debug.apk")).
		WithFile("app-debug-androidTest.apk",
			built.File("app-debug-androidTest.apk"))
}

// TestAndroidFirebase builds Android APKs and runs instrumented tests on Firebase Test Lab.
func (m *Ci) TestAndroidFirebase(
	ctx context.Context,
	serviceAccountKey *dagger.Secret,
	projectID string,
) (string, error) {
	apks := m.BuildAndroidDebugApks()

	return dag.Container().
		From("google/cloud-sdk:slim").
		WithDirectory("/apks", apks).
		WithSecretVariable("FIREBASE_SA_KEY", serviceAccountKey).
		WithEnvVariable("FIREBASE_PROJECT_ID", projectID).
		WithExec([]string{"/bin/bash", "-c",
			`auth_err=$(mktemp); trap 'rm -f "$auth_err"' EXIT; \
			 echo "$FIREBASE_SA_KEY" > /tmp/key.json; \
			 gcloud auth activate-service-account --key-file=/tmp/key.json 2>"$auth_err" \
			   || { cat "$auth_err"; exit 1; }; \
			 rm -f /tmp/key.json; \
			 gcloud config set project "$FIREBASE_PROJECT_ID" 2>>"$auth_err" \
			   || { cat "$auth_err"; exit 1; }; \
			 unknown=$(grep -vF "Activated service account credentials for:" "$auth_err" \
			   | grep -vF "Updated property [core/project]." | grep -v "^$" || true); \
			 [ -z "$unknown" ] || { echo "ERROR: unexpected gcloud auth output: $unknown"; exit 1; }; \
			 out=$(gcloud firebase test android run \
			   --type instrumentation \
			   --app /apks/app-debug.apk \
			   --test /apks/app-debug-androidTest.apk \
			   --device model=oriole,version=33,locale=en,orientation=portrait \
			   --results-bucket=gs://sharedinbox-ftl-results 2>&1); rc=$?; echo "$out"; \
			 [ "$rc" -eq 0 ] || { echo "ERROR: gcloud firebase test exited with code $rc"; exit "$rc"; }; \
			 echo "$out" | grep -qwi 'error' && { echo "ERROR: 'error' found in firebase test output"; exit 1; } || true; \
			 expected_devices=1; \
			 actual_devices=$(echo "$out" | grep "│" | grep -cE "(Passed|Failed|Inconclusive|Skipped)") || actual_devices=0; \
			 [ "$actual_devices" -eq "$expected_devices" ] || \
			   { echo "ERROR: expected $expected_devices test result(s) but found $actual_devices"; exit 1; }; \
			 echo "$out" | grep -q "Passed" || { echo "ERROR: no passing test results — tests failed or did not run"; exit 1; }`}).
		Stdout(ctx)
}

// BuildAndroidRelease builds the AAB with a fixed build-number so Dagger can cache it.
// versionCode and signing are applied separately via StampAndroidVersionCode + SignAndroidBundle.
func (m *Ci) BuildAndroidRelease() *dagger.File {
	return m.setup(m.androidSrc()).
		WithExec([]string{"flutter", "build", "appbundle", "--release", "--no-pub", "--build-number", "1"}).
		File("build/app/outputs/bundle/release/app-release.aab")
}

// withGoCache mounts Dagger cache volumes for GOCACHE and GOMODCACHE so Go
// builds inside the container reuse cached packages between pipeline runs.
func withGoCache(c *dagger.Container) *dagger.Container {
	return c.
		WithMountedCache("/home/ci/.cache/go-build", dag.CacheVolume("go-build-cache")).
		WithMountedCache("/home/ci/go/pkg/mod", dag.CacheVolume("go-mod-cache")).
		WithEnvVariable("GOCACHE", "/home/ci/.cache/go-build").
		WithEnvVariable("GOMODCACHE", "/home/ci/go/pkg/mod")
}

// UploadToPlayStore uploads a pre-built AAB to the Play Store internal track.
func (m *Ci) UploadToPlayStore(
	ctx context.Context,
	aab *dagger.File,
	playStoreConfig *dagger.Secret,
) (string, error) {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/deploy_playstore.py"},
	})

	return dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"apk", "add", "--no-cache", "curl"}).
		WithMountedCache("/root/.cache/pip", dag.CacheVolume("pip-cache")).
		WithExec([]string{"pip", "install", "requests", "google-auth"}).
		WithFile("/src/build/app/outputs/bundle/release/app-release.aab", aab).
		WithFile("/src/scripts/deploy_playstore.py", scriptSource.File("scripts/deploy_playstore.py")).
		WithSecretVariable("PLAY_STORE_CONFIG_JSON", playStoreConfig).
		WithWorkdir("/src").
		WithExec([]string{"python3", "scripts/deploy_playstore.py"}).
		Stdout(ctx)
}

// StampAndroidVersionCode patches the versionCode in a built AAB without rebuilding.
func (m *Ci) StampAndroidVersionCode(aab *dagger.File, versionCode int) *dagger.File {
	return dag.Container().
		From("python:3.12-alpine").
		WithNewFile("/patch.py", patchAabScript).
		WithFile("/in.aab", aab).
		WithExec([]string{"python3", "/patch.py", "/in.aab", "/out.aab", fmt.Sprintf("%d", versionCode)}).
		File("/out.aab")
}

// SignAndroidBundle signs an AAB with the release upload key via jarsigner.
func (m *Ci) SignAndroidBundle(aab *dagger.File, keystoreBase64 *dagger.Secret, keystorePassword *dagger.Secret) *dagger.File {
	return dag.Container().
		From("eclipse-temurin:17-jdk-alpine").
		WithFile("/app.aab", aab).
		WithSecretVariable("KS_BASE64", keystoreBase64).
		WithSecretVariable("KS_PASS", keystorePassword).
		WithExec([]string{"sh", "-c",
			`[ -n "$KS_BASE64" ] || { echo "ERROR: KS_BASE64 secret is empty — ANDROID_KEYSTORE_BASE64 not set"; exit 1; }
			 [ -n "$KS_PASS" ]   || { echo "ERROR: KS_PASS secret is empty — ANDROID_KEYSTORE_PASSWORD not set"; exit 1; }
			 echo "$KS_BASE64" | base64 -d > /keystore.jks && \
			 jarsigner -sigalg SHA256withRSA -digestalg SHA-256 \
			 -signedjar /signed.aab \
			 -keystore /keystore.jks \
			 -storepass "$KS_PASS" -keypass "$KS_PASS" \
			 /app.aab upload`}).
		File("/signed.aab")
}

// PublishAndroid builds a cached AAB, stamps the versionCode, re-signs, and uploads to Play Store.
func (m *Ci) PublishAndroid(
	ctx context.Context,
	playStoreConfig *dagger.Secret,
	keystoreBase64 *dagger.Secret,
	keystorePassword *dagger.Secret,
) (string, error) {
	versionCode := int(time.Now().Unix())
	aab := m.BuildAndroidRelease()
	stamped := m.StampAndroidVersionCode(aab, versionCode)
	signed := m.SignAndroidBundle(stamped, keystoreBase64, keystorePassword)
	return m.UploadToPlayStore(ctx, signed, playStoreConfig)
}

// Graph returns a Mermaid diagram of the CI pipeline structure.
// Paste the output into any Mermaid renderer (codeberg, github, mermaid.live)
// or save it as a .md file to get a rendered diagram.
//
// Usage:
//
//	dagger call --progress=plain -q -m ci --source=. graph
func (m *Ci) Graph() string {
	return `# CI Pipeline Graph

` + "```" + `mermaid
flowchart TD
    subgraph dagger ["Dagger · Check pipeline"]
        toolchain["toolchain\nflutter:3.41.6 + NDK + apt"]
        pubGet["pubGetLayer\nflutter pub get"]
        codegen["codegenBase\nbuild_runner build\n(shared cache)"]
        stalwart(["Stalwart service\nIMAP · JMAP · SMTP · Sieve"])

        toolchain --> pubGet
        pubGet --> codegen

        pubGet --> hygiene["CheckHygiene"]
        pubGet --> layers["CheckLayers"]
        pubGet --> mocks["CheckMocks\n(own build_runner run)"]

        codegen --> fmt["Format"]
        codegen --> analyze["Analyze"]
        codegen --> coverage["Coverage\nunit tests + gate"]
        codegen --> backend["TestBackend\nIMAP / JMAP"]
        codegen --> integration["TestIntegration\nXvfb · Linux desktop"]

        stalwart --> backend
        stalwart --> integration

        hygiene    --> check{{"✓ Check"}}
        layers     --> check
        fmt        --> check
        analyze    --> check
        mocks      --> check
        coverage   --> check
        backend    --> check
        integration --> check
    end

    subgraph forgejo ["Codeberg CI · .forgejo/workflows/ci.yml"]
        ciCheck["check"]
        buildLinux["build-linux\n(main only)"]
        deployPS["deploy-playstore\n(main only)"]
        pubWeb["publish-website\n(main only)"]

        ciCheck --> buildLinux
        ciCheck --> deployPS
        buildLinux  --> pubWeb
        deployPS    --> pubWeb
    end

    check -- "task check-dagger" --> ciCheck
` + "```"
}
