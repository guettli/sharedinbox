package main

import (
	"context"
	"dagger/ci/internal/dagger"
	"encoding/json"
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
	Source         *dagger.Directory
	FlutterVersion string
}

func New(
	ctx context.Context,
	// +defaultPath=".."
	source *dagger.Directory,
) (*Ci, error) {
	fvmrcContents, err := source.File(".fvmrc").Contents(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to read .fvmrc: %w", err)
	}
	var fvmrc struct {
		Flutter string `json:"flutter"`
	}
	if err := json.Unmarshal([]byte(fvmrcContents), &fvmrc); err != nil {
		return nil, fmt.Errorf("failed to parse .fvmrc: %w", err)
	}
	if fvmrc.Flutter == "" {
		return nil, fmt.Errorf(".fvmrc is missing the 'flutter' field")
	}
	return &Ci{
		FlutterVersion: fvmrc.Flutter,
		Source: source.Filter(dagger.DirectoryFilterOpts{
			Include: []string{
				".fvmrc",
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
	}, nil
}

// toolchain returns the Flutter+Android toolchain without any mutable cache mounts.
// Its execution cache key is stable until the image, apt packages, or SDK versions change.
// Used as the base for pubGetLayer so flutter pub get is execution-cached between runs.
func (m *Ci) toolchain() *dagger.Container {
	return dag.Container().
		From("ghcr.io/cirruslabs/flutter:"+m.FlutterVersion).
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
				`yes | sdkmanager "ndk;28.2.13676358" "cmake;3.22.1" "build-tools;35.0.0" "platforms;android-34" >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }`}).
		WithExec([]string{"flutter", "precache", "--linux", "--no-android", "--no-ios"}).
		// libssl-dev — sqlcipher_flutter_libs compiles SQLCipher against OpenSSL
		// on the Linux desktop integration_test build; its CMake
		// find_package(OpenSSL) fails without the dev headers (#582). Installed
		// here, AFTER the expensive Android-SDK/precache layers, so it does not
		// invalidate their cache and force a full cold rebuild. update+install
		// share one exec so a stale cached index can't pin a superseded .deb (404).
		WithUser("root").
		WithExec([]string{"/bin/sh", "-c", "apt-get -qq update && apt-get install -y -qq libssl-dev"}).
		WithUser("ci")
}

// Base is the Flutter toolchain container with mutable cache mounts attached.
// Use for Android/Gradle builds that need the Gradle cache.
func (m *Ci) Base() *dagger.Container {
	return m.toolchain().
		WithMountedCache("/home/ci/.gradle", dag.CacheVolume("gradle-cache"), dagger.ContainerWithMountedCacheOpts{Owner: "ci"})
}

// pubGetLayer runs flutter pub get with only pubspec.yaml + pubspec.lock as
// inputs, then removes non-deterministic fields from both package_config.json
// and .flutter-plugins-dependencies so the snapshot is byte-for-byte stable
// across runs. Re-executes only when pubspec.yaml or pubspec.lock changes.
// Packages land in the execution-cache snapshot (not a named volume) so that
// dagger prune can reclaim space from stale pubspec.lock snapshots.
func (m *Ci) pubGetLayer() *dagger.Container {
	pubspecOnly := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"pubspec.yaml", "pubspec.lock"},
	})
	return m.toolchain().
		WithDirectory("/src", pubspecOnly, dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter pub get >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -vE '^(\+|Downloading packages)' "$tmp" || true`}).
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
				`grep -vE '^\[.*s\] \|' "$tmp" || true`})
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

// androidBase wraps setup(androidSrc()) with the Gradle named-cache so that
// Gradle dependencies survive across Dagger execution-cache misses.
//
// GRADLE_OPTS disables the Gradle daemon for every invocation in this
// container. Each WithExec runs in its own ephemeral container, so a daemon
// cannot survive to the next exec anyway — its only lasting effect is to
// leave a stale journal-cache lock on the persistent gradle-cache volume
// that then blocks the next gradlew invocation (see issue #549/#555).
func (m *Ci) androidBase() *dagger.Container {
	return m.setup(m.androidSrc()).
		WithMountedCache("/home/ci/.gradle", dag.CacheVolume("gradle-cache"),
			dagger.ContainerWithMountedCacheOpts{Owner: "ci"}).
		WithEnvVariable("GRADLE_OPTS", "-Dorg.gradle.daemon=false")
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
		WithExec([]string{"sh", "-c", "echo '416bcfbdf5f68469ec9644dbe507da50fc21b94b69a125b059d64ed2cb4d8c27  /tmp/hugo.tar.gz' | sha256sum -c -"}).
		WithExec([]string{"tar", "-xzf", "/tmp/hugo.tar.gz", "-C", "/usr/local/bin", "hugo"}).
		WithExec([]string{"rm", "/tmp/hugo.tar.gz"}).
		WithUser("nobody")
}

// Deploy container for rsync/ssh
func (m *Ci) Deployer(sshKey *dagger.Secret, knownHosts *dagger.Secret) *dagger.Container {
	return dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "--no-cache", "add", "rsync", "openssh-client", "python3", "tar"}).
		WithExec([]string{"adduser", "-D", "-s", "/bin/sh", "deploy"}).
		// Create .ssh with strict permissions before Dagger mounts anything there,
		// so the directory is 700 (not Dagger's default 755).
		WithExec([]string{"sh", "-c", "mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh && chown deploy:deploy /home/deploy/.ssh"}).
		// Mount the raw key outside .ssh so Dagger cannot override the directory
		// permissions we just set above.
		WithMountedSecret("/tmp/id_ed25519.raw", sshKey, dagger.ContainerWithMountedSecretOpts{Mode: 0600}).
		// Normalise with Python3: strip CRLF/bare-CR, ensure trailing newline.
		// Using Python3 (not tr) changes the Dagger cache key so stale cached
		// results from the old tr-based step are not reused.
		WithExec([]string{"python3", "-c",
			"import os; raw=open('/tmp/id_ed25519.raw','rb').read(); key=raw.replace(b'\\r\\n',b'\\n').replace(b'\\r',b'\\n'); key=key if key.endswith(b'\\n') else key+b'\\n'; open('/home/deploy/.ssh/id_ed25519','wb').write(key); os.chmod('/home/deploy/.ssh/id_ed25519',0o600); os.chown('/home/deploy/.ssh/id_ed25519', __import__('pwd').getpwnam('deploy').pw_uid, __import__('pwd').getpwnam('deploy').pw_gid)"}).
		WithMountedSecret("/home/deploy/.ssh/known_hosts", knownHosts, dagger.ContainerWithMountedSecretOpts{Mode: 0644}).
		WithUser("deploy").
		WithEnvVariable("RSYNC_RSH", "ssh -i /home/deploy/.ssh/id_ed25519")
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
		WithUser("nobody").
		WithExec([]string{"sqlite3", "/tmp/stalwart/data.sqlite", "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL); INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');"}).
		Directory("/tmp/stalwart")

	return dag.Container().
		From("stalwartlabs/stalwart:v0.14.1").
		WithFile("/etc/stalwart/config.toml.orig", config).
		WithExec([]string{"/bin/sh", "-c", "sed -e 's/hostname = \"localhost\"/hostname = \"stalwart\"/' /etc/stalwart/config.toml.orig > /etc/stalwart/config.toml"}).
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

// FormatWrite formats Dart files and exports the modified /src directory.
func (m *Ci) FormatWrite() *dagger.Directory {
	return m.setup(m.checkSrc()).
		WithExec([]string{"dart", "format", "lib", "test"}).
		Directory("/src")
}

// Analyze runs static analysis with dart analyze --fatal-infos.
func (m *Ci) Analyze(ctx context.Context) (string, error) {
	return m.setup(m.checkSrc()).
		WithExec([]string{"dart", "analyze", "--fatal-infos"}).
		Stdout(ctx)
}

// Codegen runs build_runner and exports the modified /src directory.
func (m *Ci) Codegen() *dagger.Directory {
	return m.codegenBase().Directory("/src")
}

// AnalyzeFix runs dart fix --apply and exports the modified /src directory.
func (m *Ci) AnalyzeFix() *dagger.Directory {
	return m.setup(m.checkSrc()).
		WithExec([]string{"dart", "fix", "--apply"}).
		Directory("/src")
}

// CheckFast runs fast checks (hygiene, layers, format, analyze, mocks, coverage) in parallel.
func (m *Ci) CheckFast(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()

	var eg errgroup.Group
	eg.Go(func() error {
		_, err := m.CheckHygiene(ctx)
		return err
	})
	eg.Go(func() error {
		_, err := m.CheckLayers(ctx)
		return err
	})
	eg.Go(func() error {
		_, err := m.Format(ctx)
		return err
	})
	eg.Go(func() error {
		_, err := m.Analyze(ctx)
		return err
	})
	eg.Go(func() error {
		_, err := m.CheckGenerated(ctx)
		return err
	})
	eg.Go(func() error {
		_, err := m.Coverage(ctx)
		return err
	})
	if err := eg.Wait(); err != nil {
		return "", err
	}
	return "All fast checks passed!", nil
}

// CheckGenerated verifies that all generated files (*.g.dart, *.mocks.dart) are up to date.
// It reuses the codegenBase() output instead of running build_runner a second time,
// diffing committed generated files against the freshly built ones.
func (m *Ci) CheckGenerated(ctx context.Context) (string, error) {
	fresh := m.codegenBase().Directory("/src")
	return m.pubGetLayer().
		WithDirectory("/committed", m.checkSrc(), dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithDirectory("/generated", fresh, dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithExec([]string{"/bin/bash", "-c",
			`stale=$(find /committed -name '*.g.dart' -o -name '*.mocks.dart' | ` +
				`while IFS= read -r f; do rel="${f#/committed/}"; diff -q "$f" "/generated/$rel" >/dev/null 2>&1 || echo "$rel"; done); ` +
				`if [ -n "$stale" ]; then ` +
				`echo "ERROR: Generated files are out of date — run: dart run build_runner build"; echo "$stale"; exit 1; ` +
				`else echo "Generated files are up to date."; fi`}).
		Stdout(ctx)
}

// Coverage runs unit and widget tests with coverage gate.
func (m *Ci) Coverage(ctx context.Context) (string, error) {
	return m.setup(m.checkSrc()).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter test test/unit test/widget --exclude-tags golden --coverage --reporter expanded --no-pub >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`grep -E '^All [0-9]+ tests passed' "$tmp" || tail -1 "$tmp"`}).
		WithExec([]string{"dart", "scripts/check_coverage.dart"}).
		Stdout(ctx)
}

// TestBackend runs IMAP/JMAP sync tests against a live Stalwart instance.
func (m *Ci) TestBackend(ctx context.Context) (string, error) {
	return m.WithStalwart(m.setup(m.backendSrc())).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter test --concurrency=1 --reporter expanded --no-pub --exclude-tags=nightly test/backend >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
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

func (m *Ci) ChaosMonkeyBackend(ctx context.Context) (string, error) {
	return m.WithStalwart(m.setup(m.backendSrc())).
		WithExec([]string{"flutter", "test", "test/backend/chaos_monkey_test.dart", "--reporter", "expanded", "--concurrency=1", "--no-pub", "--tags=nightly"}).
		Stdout(ctx)
}

// Check runs the full check suite.
func (m *Ci) Check(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	// Run cheap structural checks in parallel for faster fail detection.
	var fastEg errgroup.Group
	fastEg.Go(func() error {
		_, err := m.CheckHygiene(ctx)
		return err
	})
	fastEg.Go(func() error {
		_, err := m.CheckLayers(ctx)
		return err
	})
	if err := fastEg.Wait(); err != nil {
		return "", err
	}

	// Run format, analyze, generated-code check, and coverage in parallel —
	// they all share the same setup base and have no dependencies on each other.
	var analyze, mocks, coverage string
	var checkEg errgroup.Group
	checkEg.Go(func() error {
		setup := m.setup(m.checkSrc())
		_, err := setup.WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).Stdout(ctx)
		return err
	})
	checkEg.Go(func() error {
		setup := m.setup(m.checkSrc())
		var err error
		analyze, err = setup.WithExec([]string{"dart", "analyze", "--fatal-infos"}).Stdout(ctx)
		return err
	})
	checkEg.Go(func() error {
		var err error
		mocks, err = m.CheckGenerated(ctx)
		return err
	})
	checkEg.Go(func() error {
		var err error
		coverage, err = m.Coverage(ctx)
		return err
	})
	if err := checkEg.Wait(); err != nil {
		return "", err
	}

	// Use errgroup.Group (not WithContext) so a failing test does not cancel its
	// sibling via context — which would surface as "context canceled" in dagger
	// output and trigger spurious retries in check-dagger.
	var testBackend, testIntegration string
	var eg errgroup.Group
	eg.Go(func() error {
		var e error
		testBackend, e = m.TestBackend(ctx)
		return e
	})
	eg.Go(func() error {
		var e error
		testIntegration, e = m.TestIntegration(ctx)
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
	knownHosts *dagger.Secret,
	sshUser string,
	sshHost string,
) *dagger.Directory {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/generate_build_history.py", "website/"},
	})

	return dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"apk", "add", "--no-cache", "openssh-client"}).
		WithExec([]string{"adduser", "-D", "-s", "/bin/sh", "deploy"}).
		WithExec([]string{"sh", "-c", "mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh && chown deploy:deploy /home/deploy/.ssh"}).
		WithMountedSecret("/home/deploy/.ssh/id_ed25519", sshKey, dagger.ContainerWithMountedSecretOpts{Mode: 0600}).
		WithMountedSecret("/home/deploy/.ssh/known_hosts", knownHosts, dagger.ContainerWithMountedSecretOpts{Mode: 0644}).
		WithEnvVariable("SSH_USER", sshUser).
		WithEnvVariable("SSH_HOST", sshHost).
		WithDirectory("/src", scriptSource, dagger.ContainerWithDirectoryOpts{Owner: "deploy"}).
		WithWorkdir("/src").
		WithUser("deploy").
		WithExec([]string{"/bin/sh", "-c", "python3 scripts/generate_build_history.py"}).
		Directory("website/content/builds")
}

// BuildWebsite builds the Hugo-based website.
func (m *Ci) BuildWebsite(
	ctx context.Context,
	sshKey *dagger.Secret,
	knownHosts *dagger.Secret,
	sshUser string,
	sshHost string,
	// +optional
	commitHash string,
) *dagger.Directory {
	buildHistory := m.GenerateBuildHistory(ctx, sshKey, knownHosts, sshUser, sshHost)

	websiteSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"website/"},
	}).WithDirectory("website/content/builds", buildHistory)

	hugo := m.Hugo().
		WithDirectory("/src", websiteSource, dagger.ContainerWithDirectoryOpts{Owner: "nobody"}).
		WithWorkdir("/src/website")
	if commitHash != "" {
		hugo = hugo.WithEnvVariable("HUGO_PARAMS_GITVERSION", commitHash)
	}
	return hugo.
		WithExec([]string{"hugo", "--minify", "--destination", "/tmp/public"}).
		Directory("/tmp/public")
}

// PublishWebsite builds and deploys the website to the remote server.
func (m *Ci) PublishWebsite(
	ctx context.Context,
	sshKey *dagger.Secret,
	knownHosts *dagger.Secret,
	sshUser string,
	sshHost string,
	// +optional
	commitHash string,
) (string, error) {
	public := m.BuildWebsite(ctx, sshKey, knownHosts, sshUser, sshHost, commitHash)

	return m.Deployer(sshKey, knownHosts).
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
func (m *Ci) BuildLinuxRelease(
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
) *dagger.Directory {
	args := []string{"flutter", "build", "linux", "--release"}
	if commitHash != "" {
		args = append(args, "--dart-define=GIT_HASH="+commitHash)
	}
	return m.setup(m.linuxSrc()).
		WithExec(args).
		Directory("build/linux/x64/release/bundle")
}

// DeployLinux packages and deploys the Linux release to the server.
func (m *Ci) DeployLinux(
	ctx context.Context,
	sshKey *dagger.Secret,
	knownHosts *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
) (string, error) {
	bundle := m.BuildLinuxRelease(commitHash)

	datePath := time.Now().Format("2006/01/02")
	remoteDir := fmt.Sprintf("public_html/builds/%s", datePath)
	tarball := fmt.Sprintf("sharedinbox-linux-amd64-%s.tar.gz", commitHash)

	return m.Deployer(sshKey, knownHosts).
		WithDirectory("/bundle", bundle).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("tar -czf /tmp/%s -C /bundle .", tarball)}).
		WithExec([]string{"ssh", "-i", "/home/deploy/.ssh/id_ed25519", fmt.Sprintf("%s@%s", sshUser, sshHost), fmt.Sprintf("mkdir -p %s", remoteDir)}).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("scp -i /home/deploy/.ssh/id_ed25519 /tmp/%s %s@%s:%s/%s", tarball, sshUser, sshHost, remoteDir, tarball)}).
		Stdout(ctx)
}

// setupKeystore decodes the base64 keystore into the android build container.
func (m *Ci) setupKeystore(keystoreBase64 *dagger.Secret, keystorePassword *dagger.Secret) *dagger.Container {
	return m.androidBase().
		WithSecretVariable("ANDROID_KEYSTORE_BASE64", keystoreBase64).
		WithSecretVariable("ANDROID_KEYSTORE_PASSWORD", keystorePassword).
		WithExec([]string{"/bin/sh", "-c", `echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > /tmp/upload-keystore.jks`}).
		WithEnvVariable("ANDROID_KEYSTORE_PATH", "/tmp/upload-keystore.jks")
}

// BuildAndroidApk builds a release APK signed with the upload key.
func (m *Ci) BuildAndroidApk(
	keystoreBase64 *dagger.Secret,
	keystorePassword *dagger.Secret,
	buildNumber string,
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
) *dagger.File {
	args := []string{"flutter", "build", "apk", "--release", "--no-pub", "--build-number", buildNumber}
	if commitHash != "" {
		args = append(args, "--dart-define=GIT_HASH="+commitHash)
	}
	return m.setupKeystore(keystoreBase64, keystorePassword).
		WithExec(args).
		File("build/app/outputs/flutter-apk/app-release.apk")
}

// DeployApk builds and deploys the APK to the server.
func (m *Ci) DeployApk(
	ctx context.Context,
	sshKey *dagger.Secret,
	knownHosts *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
	keystoreBase64 *dagger.Secret,
	keystorePassword *dagger.Secret,
	buildNumber string,
) (string, error) {
	apk := m.BuildAndroidApk(keystoreBase64, keystorePassword, buildNumber, commitHash)

	datePath := time.Now().Format("2006/01/02")
	remoteDir := fmt.Sprintf("public_html/builds/%s", datePath)
	apkName := fmt.Sprintf("sharedinbox-mua-%s.apk", commitHash)

	return m.Deployer(sshKey, knownHosts).
		WithFile("/tmp/app.apk", apk).
		WithExec([]string{"ssh", "-i", "/home/deploy/.ssh/id_ed25519", fmt.Sprintf("%s@%s", sshUser, sshHost), fmt.Sprintf("mkdir -p %s", remoteDir)}).
		WithExec([]string{"/bin/sh", "-c", fmt.Sprintf("scp -i /home/deploy/.ssh/id_ed25519 /tmp/app.apk %s@%s:%s/%s", sshUser, sshHost, remoteDir, apkName)}).
		Stdout(ctx)
}

// TestAndroidFirebase runs a Firebase Test Lab robo crawl against the split
// APKs of the Play Store alpha release. Callers (scripts/run_firebase_test.sh)
// supply the APK directory after downloading via fetch_playstore_apks.py so
// the test exercises exactly the binary users install — not a debug build.
//
// The robo crawl drives the app for 90s. We fail the run if the gcloud table
// reports anything other than "Passed", if the output mentions known crash
// markers (FATAL EXCEPTION / "has died" / "Crashed"), or if gcloud itself
// returns a Robo-specific failure string.
func (m *Ci) TestAndroidFirebase(
	ctx context.Context,
	// Directory containing the Play Store split APKs. Must include a
	// base-master.apk; everything else is forwarded as --additional-apks.
	apks *dagger.Directory,
	serviceAccountKey *dagger.Secret,
	projectID string,
) (string, error) {
	return dag.Container().
		From("google/cloud-sdk:slim").
		WithDirectory("/apks", apks).
		WithSecretVariable("FIREBASE_SA_KEY", serviceAccountKey).
		WithEnvVariable("FIREBASE_PROJECT_ID", projectID).
		WithUser("cloudsdk").
		WithExec([]string{"/bin/bash", "-c",
			`auth_err=$(mktemp); trap 'rm -f "$auth_err"' EXIT; \
			 gcloud auth activate-service-account --key-file=<(echo "$FIREBASE_SA_KEY") 2>"$auth_err" \
			   || { cat "$auth_err"; exit 1; }; \
			 gcloud config set project "$FIREBASE_PROJECT_ID" 2>>"$auth_err" \
			   || { cat "$auth_err"; exit 1; }; \
			 unknown=$(grep -vF "Activated service account credentials for:" "$auth_err" \
			   | grep -vF "Updated property [core/project]." | grep -v "^$" || true); \
			 [ -z "$unknown" ] || { echo "ERROR: unexpected gcloud auth output: $unknown"; exit 1; }; \
			 ls /apks; \
			 app="/apks/base-master.apk"; \
			 [ -f "$app" ] || { echo "ERROR: base-master.apk missing from /apks"; exit 1; }; \
			 extras=$(find /apks -maxdepth 1 -name "*.apk" -not -name "base-master.apk" -printf "%p," | sed "s/,$//"); \
			 extra_args=(); [ -n "$extras" ] && extra_args=(--additional-apks "$extras"); \
			 out=$(gcloud firebase test android run \
			   --type robo \
			   --app "$app" \
			   "${extra_args[@]}" \
			   --device model=oriole,version=33,locale=en,orientation=portrait \
			   --timeout 90s \
			   --results-bucket=gs://sharedinbox-ftl-results 2>&1); rc=$?; echo "$out"; \
			 [ "$rc" -eq 0 ] || { echo "ERROR: gcloud firebase test exited with code $rc"; exit "$rc"; }; \
			 if echo "$out" | grep -qE "FATAL EXCEPTION|Process .* has died|Crashed|Error: Robo test failed"; then \
			   echo "ERROR: alpha APK crashed during robo crawl"; exit 1; \
			 fi; \
			 outcomes=$(echo "$out" | grep "│" | grep -cE "(Passed|Failed|Inconclusive|Skipped)") || outcomes=0; \
			 [ "$outcomes" -ge 1 ] || { echo "ERROR: no outcome row found in gcloud output"; exit 1; }; \
			 if echo "$out" | grep "│" | grep -qE "(Failed|Inconclusive)"; then \
			   echo "ERROR: robo crawl reported Failed/Inconclusive outcome"; exit 1; \
			 fi; \
			 echo "$out" | grep "│" | grep -q "Passed" || { echo "ERROR: no Passed outcome — alpha APK did not survive robo crawl"; exit 1; }`}).
		Stdout(ctx)
}

// buildAndroidReleaseDir runs `flutter build appbundle --release` once and
// returns build/app/outputs/ so callers can select both the AAB and the R8
// mapping file from a single cached execution.
func (m *Ci) buildAndroidReleaseDir(commitHash string) *dagger.Directory {
	args := []string{"flutter", "build", "appbundle", "--release", "--no-pub", "--build-number", "1"}
	if commitHash != "" {
		args = append(args, "--dart-define=GIT_HASH="+commitHash)
	}
	return m.androidBase().
		WithExec(args).
		Directory("build/app/outputs")
}

// BuildAndroidRelease builds the AAB with a fixed build-number so Dagger can cache it.
// versionCode and signing are applied separately via StampAndroidVersionCode + SignAndroidBundle.
func (m *Ci) BuildAndroidRelease(
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
) *dagger.File {
	return m.buildAndroidReleaseDir(commitHash).
		File("bundle/release/app-release.aab")
}

// BuildAndroidReleaseMapping returns the R8 mapping file produced by the same
// release build as BuildAndroidRelease. Uploading it alongside the AAB lets
// Play Console deobfuscate crash and ANR stack traces.
func (m *Ci) BuildAndroidReleaseMapping(
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
) *dagger.File {
	return m.buildAndroidReleaseDir(commitHash).
		File("mapping/release/mapping.txt")
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

// FetchPlayStoreApks downloads the split APKs of the most recent alpha-track
// release using the Play Developer API. Returns a Directory containing the
// APKs and a ``versionCode`` text file with the resolved alpha versionCode.
// Runs in a Python container so the runner host does not need google-auth /
// requests installed (matches the UploadToPlayStore pattern).
func (m *Ci) FetchPlayStoreApks(
	playStoreConfig *dagger.Secret,
) *dagger.Directory {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/fetch_playstore_apks.py"},
	})

	return dag.Container().
		From("python:3.12-alpine").
		WithMountedCache("/tmp/pip-cache", dag.CacheVolume("pip-cache")).
		WithExec([]string{"pip", "install", "--cache-dir", "/tmp/pip-cache", "google-auth", "requests"}).
		WithFile("/src/scripts/fetch_playstore_apks.py", scriptSource.File("scripts/fetch_playstore_apks.py")).
		WithSecretVariable("PLAY_STORE_CONFIG_JSON", playStoreConfig).
		WithWorkdir("/src").
		WithUser("nobody").
		WithExec([]string{"/bin/sh", "-c",
			`mkdir -p /tmp/apks && python3 scripts/fetch_playstore_apks.py /tmp/apks`}).
		Directory("/tmp/apks")
}

// UploadToPlayStore uploads a pre-built AAB to the Play Store closed-testing (alpha) track.
// When mappingFile is provided, its contents are also uploaded as the R8
// deobfuscation file so Play Console can deobfuscate stack traces.
func (m *Ci) UploadToPlayStore(
	ctx context.Context,
	aab *dagger.File,
	playStoreConfig *dagger.Secret,
	// +optional
	mappingFile *dagger.File,
) (string, error) {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/deploy_playstore.py"},
	})

	container := dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"apk", "add", "--no-cache", "curl"}).
		WithMountedCache("/tmp/pip-cache", dag.CacheVolume("pip-cache")).
		WithExec([]string{"pip", "install", "--cache-dir", "/tmp/pip-cache", "google-auth", "requests"}).
		WithFile("/src/build/app/outputs/bundle/release/app-release.aab", aab).
		WithFile("/src/scripts/deploy_playstore.py", scriptSource.File("scripts/deploy_playstore.py")).
		WithSecretVariable("PLAY_STORE_CONFIG_JSON", playStoreConfig).
		WithWorkdir("/src")

	if mappingFile != nil {
		const mappingPath = "/src/build/app/outputs/mapping/release/mapping.txt"
		container = container.
			WithFile(mappingPath, mappingFile).
			WithEnvVariable("MAPPING_TXT_PATH", mappingPath)
	}

	return container.
		WithUser("nobody").
		WithExec([]string{"python3", "scripts/deploy_playstore.py"}).
		Stdout(ctx)
}

// StampAndroidVersionCode patches the versionCode in a built AAB without rebuilding.
func (m *Ci) StampAndroidVersionCode(aab *dagger.File, versionCode int) *dagger.File {
	return dag.Container().
		From("python:3.12-alpine").
		WithNewFile("/tmp/patch.py", patchAabScript).
		WithFile("/tmp/in.aab", aab).
		WithUser("nobody").
		WithExec([]string{"python3", "/tmp/patch.py", "/tmp/in.aab", "/tmp/out.aab", fmt.Sprintf("%d", versionCode)}).
		File("/tmp/out.aab")
}

// SignAndroidBundle signs an AAB with the release upload key via jarsigner.
func (m *Ci) SignAndroidBundle(aab *dagger.File, keystoreBase64 *dagger.Secret, keystorePassword *dagger.Secret) *dagger.File {
	return dag.Container().
		From("eclipse-temurin:17-jdk-alpine").
		WithFile("/tmp/app.aab", aab).
		WithSecretVariable("KS_BASE64", keystoreBase64).
		WithSecretVariable("KS_PASS", keystorePassword).
		WithUser("nobody").
		WithExec([]string{"sh", "-c",
			`[ -n "$KS_BASE64" ] || { echo "ERROR: KS_BASE64 secret is empty — ANDROID_KEYSTORE_BASE64 not set"; exit 1; }
			 [ -n "$KS_PASS" ]   || { echo "ERROR: KS_PASS secret is empty — ANDROID_KEYSTORE_PASSWORD not set"; exit 1; }
			 echo "$KS_BASE64" | base64 -d > /tmp/keystore.jks && \
			 jarsigner -sigalg SHA256withRSA -digestalg SHA-256 \
			 -signedjar /tmp/signed.aab \
			 -keystore /tmp/keystore.jks \
			 -storepass:env KS_PASS -keypass:env KS_PASS \
			 /tmp/app.aab upload`}).
		File("/tmp/signed.aab")
}

// PublishAndroid builds a cached AAB, stamps the versionCode, re-signs, and uploads to Play Store
// together with the R8 mapping file produced by the same build.
func (m *Ci) PublishAndroid(
	ctx context.Context,
	playStoreConfig *dagger.Secret,
	keystoreBase64 *dagger.Secret,
	keystorePassword *dagger.Secret,
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
) (string, error) {
	versionCode := int(time.Now().Unix())
	buildDir := m.buildAndroidReleaseDir(commitHash)
	aab := buildDir.File("bundle/release/app-release.aab")
	mapping := buildDir.File("mapping/release/mapping.txt")
	stamped := m.StampAndroidVersionCode(aab, versionCode)
	signed := m.SignAndroidBundle(stamped, keystoreBase64, keystorePassword)
	return m.UploadToPlayStore(ctx, signed, playStoreConfig, mapping)
}

// Renovate runs Renovate bot against the repository on the sialoop Gitea instance.
func (m *Ci) Renovate(
	ctx context.Context,
	renovateToken *dagger.Secret,
	// +optional
	githubToken *dagger.Secret,
) (string, error) {
	// Codeberg's GET /pulls?state=all&limit=100 times out with a 504, but limit=10
	// completes in ~9 s. Patch the compiled pr-cache.js to use 10 instead of the
	// hardcoded 20/100 values before launching renovate.
	const patchCmd = `for f in \
			/usr/local/renovate/dist/modules/platform/forgejo/pr-cache.js \
			/usr/local/renovate/dist/modules/platform/gitea/pr-cache.js; do \
		sed -i 's/limit: this\.items\.length ? 20 : 100/limit: this.items.length ? 10 : 10/' "$f" && echo "patched $f"; \
		done`
	container := dag.Container().
		From("renovate/renovate:43").
		WithSecretVariable("RENOVATE_TOKEN", renovateToken)
	if githubToken != nil {
		container = container.WithSecretVariable("GITHUB_COM_TOKEN", githubToken)
	}
	return container.
		WithEnvVariable("RENOVATE_PLATFORM", "gitea").
		WithEnvVariable("RENOVATE_ENDPOINT", "https://sialoop.thomas-guettler.de").
		WithEnvVariable("RENOVATE_REPOSITORIES", "guettli/sharedinbox").
		WithEnvVariable("LOG_LEVEL", "info").
		WithUser("root").
		WithExec([]string{"/bin/sh", "-c", patchCmd}).
		WithUser("ubuntu").
		WithExec([]string{"renovate"}).
		Stdout(ctx)
}

// Graph returns a Mermaid diagram of the CI pipeline structure.
// Paste the output into any Mermaid renderer (codeberg, github, mermaid.live)
// or save it as a .md file to get a rendered diagram.
//
// Usage:
//
//	dagger call --progress=plain -q -m ci --source=. graph
func (m *Ci) Graph() string {
	return fmt.Sprintf(`# CI Pipeline Graph

`+"```"+`mermaid
flowchart TD
    subgraph dagger ["Dagger · Check pipeline"]
        toolchain["toolchain\nflutter:%s + NDK + apt + precache"]`, m.FlutterVersion) + `
        pubGet["pubGetLayer\nflutter pub get"]
        codegen["codegenBase\nbuild_runner build\n(shared cache)"]
        stalwart(["Stalwart service\nIMAP · JMAP · SMTP · Sieve"])

        toolchain --> pubGet
        pubGet --> codegen

        pubGet --> hygiene["CheckHygiene"]
        pubGet --> layers["CheckLayers"]
        pubGet --> mocks["CheckGenerated\n(own build_runner run)"]

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

    subgraph forgejo_ci ["Codeberg CI · ci.yml (push/PR, source paths only)"]
        ciCheck["check"]
    end

    subgraph forgejo_deploy ["Codeberg CI · deploy.yml (hourly schedule + workflow_dispatch)"]
        detectChanges["check-changes\ndetect android / linux diff"]
        buildLinux["build-linux\n(linux changed)"]
        deployPS["deploy-playstore\n(android changed)"]
        deployApk["deploy-apk\n(android changed)"]
        pubWeb["publish-website\n(any build succeeded)"]

        detectChanges --> buildLinux
        detectChanges --> deployPS
        detectChanges --> deployApk
        buildLinux  --> pubWeb
        deployPS    --> pubWeb
        deployApk   --> pubWeb
    end

    subgraph forgejo_firebase ["Codeberg CI · firebase-tests.yml (daily cron + workflow_dispatch)"]
        fbTest["test-android-firebase\n(alpha versionCode changed)"]
    end

    check -- "task check-dagger" --> ciCheck
` + "```"
}
