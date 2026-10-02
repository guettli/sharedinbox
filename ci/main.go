package main

import (
	"context"
	"dagger/ci/internal/dagger"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/errgroup"
)

// checkTiming is one check's wall-clock cost, recorded by timedCheck.
type checkTiming struct {
	phase string
	name  string
	dur   time.Duration
	ok    bool
}

// timedCheck runs fn and records its wall-time under (phase, name).
//
// Per-check wall-times are the numbers CI could not previously see. GitHub's UI
// shows only the single opaque "Run Full Check Suite" step, and Dagger's OTEL
// spans for the actual work are unlabeled ("resume withExec" / "Container.stdout"),
// so a slow check is invisible in a trace. Recording it here makes the breakdown
// show up in EVERY run's log — PRs included, which is exactly the cold-cache case
// the main-only OTEL export (see .github/workflows/ci.yml, issue #649) never
// measures.
func timedCheck(mu *sync.Mutex, out *[]checkTiming, phase, name string, fn func() error) error {
	start := time.Now()
	err := fn()
	mu.Lock()
	*out = append(*out, checkTiming{phase: phase, name: name, dur: time.Since(start), ok: err == nil})
	mu.Unlock()
	return err
}

// formatCheckTimings renders the per-check breakdown as a table sorted slowest
// first. Checks inside a phase run in parallel, so a phase's wall-time is its
// slowest member — that member is the one to optimise.
func formatCheckTimings(timings []checkTiming) string {
	sort.SliceStable(timings, func(i, j int) bool { return timings[i].dur > timings[j].dur })
	b := &strings.Builder{}
	fmt.Fprintf(b, "\n=== Per-check wall-times (slowest first) ===\n")
	for _, t := range timings {
		status := "ok"
		if !t.ok {
			status = "FAIL"
		}
		fmt.Fprintf(b, "%8.1fs  %-6s  %-16s %s\n", t.dur.Seconds(), status, t.phase, t.name)
	}
	return b.String()
}

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
				// Duplication checker needs the whole tree it scans plus its
				// config/baseline. duplicationSrc() further narrows this, but
				// its Filter is applied on top of the constructor's Filter —
				// paths not in the constructor's Include list are already
				// gone by the time duplicationSrc runs, which is what
				// silently zeroed out the Go detector and the baseline
				// lookup in the past.
				"hooks/",
				"deploy_cron.py",
				"ci/",
				"server/",
				".jscpd.json",
				"duplication-baseline.json",
			},
		}),
	}, nil
}

// androidCmdlineToolsURL pins the Android SDK command-line tools bundle used
// to install NDK / build-tools / platforms. Bump manually only when a newer
// sdkmanager package requires it.
const androidCmdlineToolsURL = "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

// flutterArchiveURLTemplate is the official Flutter SDK archive. The stable
// channel publishes an image for EVERY stable release (including patch
// releases that ghcr.io/cirruslabs/flutter skips), so installing from here
// makes every Renovate bump buildable without waiting on a third party (#394).
const flutterArchiveURLTemplate = "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_%s-stable.tar.xz"

// toolchain returns the Flutter+Android toolchain without any mutable cache mounts.
// Its execution cache key is stable until the base image, apt packages, or SDK
// versions change; a Flutter version bump invalidates only the Flutter install
// layer and the precache step below it, so the multi-GB Android SDK layers are
// reused across .fvmrc bumps.
// Used as the base for pubGetLayer so flutter pub get is execution-cached between runs.
func (m *Ci) toolchain() *dagger.Container {
	return dag.Container().
		From("ubuntu:24.04").
		WithEnvVariable("DEBIAN_FRONTEND", "noninteractive").
		WithEnvVariable("JAVA_HOME", "/usr/lib/jvm/java-17-openjdk-amd64").
		WithEnvVariable("ANDROID_HOME", "/opt/android-sdk").
		WithEnvVariable("PATH", "/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:${JAVA_HOME}/bin:${PATH}",
			dagger.ContainerWithEnvVariableOpts{Expand: true}).
		// Combined update+install so a stale cached index cannot pin a
		// superseded .deb (404). Keeping the whole apt state in one exec means
		// it lives in a single cache entry that is stable across Flutter bumps.
		WithExec([]string{"/bin/sh", "-c",
			"apt-get -qq update && apt-get install -y -qq --no-install-recommends " +
				// Flutter/Android runtime deps
				"ca-certificates curl git unzip xz-utils zip openjdk-17-jdk-headless python3 " +
				// Linux desktop build deps. SQLCipher (with OpenSSL statically
				// linked) is now bundled by package:sqlite3's build hook
				// (`source: sqlcipher`), so neither libssl-dev nor libsqlite3-dev
				// is needed any more. The `sqlite3` CLI stays: it seeds Stalwart
				// in the integration tests, unrelated to the Dart FFI package.
				"clang cmake ninja-build pkg-config " +
				"libgtk-3-dev liblzma-dev libsecret-1-dev libgcrypt20-dev libjsoncpp-dev " +
				"sqlite3 " +
				// Integration testing / networking
				"iproute2 netcat-openbsd xvfb libosmesa6 libegl1 lld"}).
		WithExec([]string{"useradd", "-m", "-s", "/bin/bash", "ci"}).
		// Install Android command-line tools and accept the SDK licenses so
		// subsequent `sdkmanager <package>` calls install without prompting.
		WithExec([]string{"/bin/sh", "-c",
			`set -e; ` +
				`mkdir -p /opt/android-sdk/cmdline-tools; ` +
				`curl -fsSL -o /tmp/cmdline-tools.zip ` + androidCmdlineToolsURL + `; ` +
				`unzip -q /tmp/cmdline-tools.zip -d /opt/android-sdk/cmdline-tools; ` +
				`mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest; ` +
				`rm /tmp/cmdline-tools.zip; ` +
				`yes | sdkmanager --licenses >/dev/null; ` +
				`chown -R ci:ci /opt/android-sdk; ` +
				`mkdir -p /src && chown ci:ci /src`}).
		WithEnvVariable("PUB_CACHE", "/home/ci/.pub-cache").
		WithEnvVariable("HOME", "/home/ci").
		WithUser("ci").
		WithExec([]string{"/bin/sh", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`yes | sdkmanager "ndk;28.2.13676358" "cmake;3.22.1" "build-tools;35.0.0" "platforms;android-34" "platforms;android-35" >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }`}).
		// Install Flutter from the official archive at the exact .fvmrc
		// version. The version is interpolated into the exec so this layer's
		// cache key changes with FlutterVersion — invalidating only the two
		// steps that follow, not the multi-GB Android SDK layers above.
		WithUser("root").
		WithExec([]string{"/bin/sh", "-c",
			fmt.Sprintf(`set -e; `+
				`curl -fsSL "`+flutterArchiveURLTemplate+`" | tar -xJ -C /opt; `+
				`git config --system --add safe.directory /opt/flutter; `+
				`chown -R ci:ci /opt/flutter`, m.FlutterVersion)}).
		WithUser("ci").
		WithExec([]string{"flutter", "precache", "--linux", "--no-android", "--no-ios"})
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
//
// The empty `android/` marker directory is what makes `flutter pub get` write
// .flutter-plugins-dependencies here. Since Flutter 3.47 (#619) pub get only
// regenerates the plugin manifest when a platform directory is present; with
// only pubspec.* in /src it would skip it entirely. The Android release build
// runs with --no-pub (BuildAndroidApk / buildAndroidReleaseDir), so it never
// regenerates the manifest itself — it relies on this snapshot's copy. Without
// it the Flutter Gradle plugin registers no plugin subprojects and the release
// assembleRelease fails to compile GeneratedPluginRegistrant.java ("package …
// does not exist" for every plugin, see #648). The manifest's contents depend
// only on the resolved package set, not on android/ contents, so a bare marker
// produces the same file the real project would; drop it afterwards so no stray
// android/ files leak into the snapshot that later overlays the real tree.
func (m *Ci) pubGetLayer() *dagger.Container {
	pubspecOnly := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"pubspec.yaml", "pubspec.lock"},
	})
	return m.toolchain().
		WithDirectory("/src", pubspecOnly, dagger.ContainerWithDirectoryOpts{Owner: "ci"}).
		WithWorkdir("/src").
		WithExec([]string{"/bin/bash", "-c",
			`mkdir -p android; ` +
				`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter pub get >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				`rm -rf android; ` +
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

// emulatorBase extends the Flutter/Android toolchain with everything needed to
// boot a headless emulator: platform-tools (adb), the emulator package, and an
// x86_64 google_apis system image, plus a pre-created AVD. Each WithExec is a
// distinct Dagger execution-cache layer, so the multi-GB system-image download
// and AVD creation happen only on the first run and are reused thereafter (#99).
//
// Everything here runs as the unprivileged ci user so the AVD lands in ci's
// HOME (~/.android/avd) — the emulator refuses to run as root, and
// SmokeTestRelease drops back to ci before booting it.
func (m *Ci) emulatorBase() *dagger.Container {
	return m.toolchain().
		WithUser("ci").
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`yes | sdkmanager "platform-tools" "emulator" "system-images;android-34;google_apis;x86_64" >"$tmp" 2>&1 ` +
				`|| { cat "$tmp"; exit 1; }`}).
		WithExec([]string{"/bin/bash", "-c",
			`echo no | avdmanager create avd -n smoke -k "system-images;android-34;google_apis;x86_64" --force`}).
		WithEnvVariable("PATH", "${ANDROID_HOME}/emulator:${ANDROID_HOME}/platform-tools:${PATH}",
			dagger.ContainerWithEnvVariableOpts{Expand: true})
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

// duplicationSrc is the source subset the Duplication checker sees. Kept
// separate from checkSrc so we can include the Go server tree (server/) and
// pre-built ci/main.go without pulling in Android / iOS scaffolding.
func (m *Ci) duplicationSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{
			"lib/",
			"test/",
			"integration_test/",
			"scripts/",
			"hooks/",
			"deploy_cron.py",
			"ci/",
			"server/",
			"stalwart-dev/",
			".jscpd.json",
			"duplication-baseline.json",
		},
		Exclude: []string{
			"**/*.g.dart",
			"**/*.freezed.dart",
			"**/*.mocks.dart",
			"**/*.pb.dart",
		},
	})
}

// duplicationBase builds the container image the duplication orchestrator
// needs. Shared between Duplication (gate) and DuplicationBaseline (artifact
// producer) so the apt/pip/go/npm install layer is cached once per invocation.
//
// Uses the golang image (goToolImage) because dupl is installed via
// `go install` and needs a recent Go toolchain; Debian's packaged Go on
// python:*-slim was too old for reliable module resolution.
func (m *Ci) duplicationBase() *dagger.Container {
	return dag.Container().
		From(goToolImage).
		WithExec([]string{"/bin/sh", "-c",
			"apt-get -qq update && " +
				"apt-get install -y -qq --no-install-recommends " +
				"python3 python3-pip nodejs npm ca-certificates && " +
				"pip install --quiet --no-cache-dir --break-system-packages pylint==4.0.6 && " +
				"GOBIN=/usr/local/bin go install github.com/mibk/dupl@v1.1.0 && " +
				// jscpd@4.2.5's transitive deps resolve to commander@15,
				// which is ESM-only and blows up under `require()` on the
				// Node 18 in this base image with `ERR_REQUIRE_ESM`. Pin
				// commander@11 (last major with CommonJS) at the parent
				// node_modules and delete jscpd's private copy so its
				// require('commander') falls through to the CommonJS one.
				"npm install --silent --no-progress --global " +
				"jscpd@4.2.5 commander@11.1.0 && " +
				"rm -rf /usr/local/lib/node_modules/jscpd/node_modules/commander"}).
		WithDirectory("/src", m.duplicationSrc()).
		WithWorkdir("/src").
		WithEnvVariable("HOME", "/tmp")
}

// Duplication runs the duplicated-code orchestrator (jscpd + pylint + dupl)
// against the committed baseline. Exits non-zero if any clone is found that
// is NOT already in duplication-baseline.json. See DEVELOPMENT.md#duplication.
func (m *Ci) Duplication(ctx context.Context) (string, error) {
	return m.duplicationBase().
		WithExec([]string{"python3", "scripts/detect_duplication.py", "--against-baseline"}).
		Stdout(ctx)
}

// DuplicationBaseline regenerates duplication-baseline.json inside the CI
// container and returns it as a file. Use when the local baseline drifts
// from the container's output (different tool versions, file ordering, etc.)
// — export with:
//
//	dagger call --progress=plain -q -m ci --source=. duplication-baseline -o duplication-baseline.json
func (m *Ci) DuplicationBaseline() *dagger.File {
	return m.duplicationBase().
		WithExec([]string{"python3", "scripts/detect_duplication.py", "--baseline"}).
		File("duplication-baseline.json")
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

// goToolImage is the single Go toolchain image for the Go-based checks — the
// gofmt gate and the dupl detector in duplicationBase. One image (not one per
// check) so cold runs pull the layer once. Pinned so gofmt output does not
// depend on a contributor's local Go version (it changes between releases, e.g.
// doc-comment reformatting landed in 1.19), and kept >= the root go.mod
// directive (1.27). Note ci/go.mod stays at 1.26: Dagger v0.21.8's SDK caps the
// module's go directive at 1.26.5, so it cannot move to 1.27 until the
// lock-stepped engine is upgraded — this image (which only runs tools, never
// builds the module) is unaffected by that cap.
const goToolImage = "golang:1.27-bookworm"

// goFmtSrc is the hand-written Go the gofmt gate checks: the ci Dagger module
// and the server binaries. Dagger's generated code is never committed and we
// don't want the gate to fail on a file no contributor can hand-fix, so it is
// excluded wherever it lands — the `*.gen.go` files (e.g. ci/dagger.gen.go) and
// the whole ci/internal client tree (see ci/.gitignore). The vendored Hugo
// theme under website/ is third-party and simply not selected.
func (m *Ci) goFmtSrc() *dagger.Directory {
	return m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"ci/", "server/"},
		Exclude: []string{"ci/internal/", "**/*.gen.go"},
	})
}

// CheckGoFormat fails if any committed Go file is not gofmt-formatted. Until
// this gate existed, CI checked only Dart (dart format), so the Go code silently
// drifted out of gofmt-clean state (issue #731). Runs gofmt in the pinned
// goToolImage for a version-stable result.
func (m *Ci) CheckGoFormat(ctx context.Context) (string, error) {
	return dag.Container().
		From(goToolImage).
		WithDirectory("/src", m.goFmtSrc()).
		WithWorkdir("/src").
		WithExec([]string{"/bin/sh", "-c",
			// `|| exit 1` catches gofmt's own non-zero exit (an unparseable Go
			// file, which it reports on stderr and omits from stdout) so a
			// broken file cannot slip through as "no diff"; the -n test then
			// catches files that parse but are not formatted.
			`unformatted="$(gofmt -l .)" || { echo "ERROR: gofmt failed (unparseable Go?)"; exit 1; }; ` +
				`if [ -n "$unformatted" ]; then ` +
				`echo "ERROR: these Go files are not gofmt-formatted (run: gofmt -w <file>):"; ` +
				`echo "$unformatted"; exit 1; ` +
				`fi; echo "Go format check passed."`}).
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

// TestFuzz runs the long-running IMAP/JMAP cross-protocol fuzz test. It is
// nightly-tagged (so it stays out of the blocking per-PR check — see #747) and
// therefore needs its own runner, exactly like ChaosMonkeyBackend.
func (m *Ci) TestFuzz(ctx context.Context) (string, error) {
	return m.WithStalwart(m.setup(m.backendSrc())).
		WithExec([]string{"flutter", "test", "test/backend/long_term_fuzz_test.dart", "--reporter", "expanded", "--concurrency=1", "--no-pub", "--tags=nightly"}).
		Stdout(ctx)
}

// GmailProbe runs the read-only Gmail inbox decode probe
// (test/backend/gmail_inbox_probe_test.dart) against a LIVE Gmail account. It
// walks INBOX newest-first through the app's real sync + decode path and stops
// at the first message that fails to decode, printing one error block; it is
// silent when every message decodes cleanly.
//
// gmailMail / gmailPassword are the address and an app-password, passed as
// Dagger secrets (never baked into the layer). Unlike the backend tests this
// does NOT attach Stalwart — it talks to imap.gmail.com directly, so it needs
// the engine's outbound network. Message-ids proven clean are recorded in a
// persistent Dagger cache volume, so a re-run skips them and advances to the
// next unseen message — the fail-forward loop.
//
// Read-only: the probe only syncs + decodes (BODY.PEEK everywhere, no
// flag/move/append writes), so it never mutates the mailbox.
func (m *Ci) GmailProbe(
	ctx context.Context,
	gmailMail *dagger.Secret,
	gmailPassword *dagger.Secret,
) (string, error) {
	return m.setup(m.backendSrc()).
		WithSecretVariable("GMAIL_MAIL", gmailMail).
		WithSecretVariable("GMAIL_PASSWORD", gmailPassword).
		WithEnvVariable("GMAIL_PROBE_CACHE", "/home/ci/.cache/gmail-probe/clean.json").
		WithMountedCache("/home/ci/.cache/gmail-probe", dag.CacheVolume("gmail-probe-cache"),
			dagger.ContainerWithMountedCacheOpts{Owner: "ci"}).
		WithExec([]string{"/bin/bash", "-c",
			`tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; ` +
				`flutter test test/backend/gmail_inbox_probe_test.dart --reporter expanded --concurrency=1 --no-pub >"$tmp" 2>&1 || { cat "$tmp"; exit 1; }; ` +
				// The probe's value is seeing what a real mailbox does, so surface the
				// enough_mail diagnostics (e.g. `fetch: encountered unexpected …`, the
				// first symptom of #680) even on a passing run — not only when the test
				// is failed on purpose to dump its buffer (issue #686).
				`grep -Ei '^fetch:|warning' "$tmp" || true; ` +
				`grep -E '^All [0-9]+ tests passed' "$tmp" || tail -1 "$tmp"`}).
		Stdout(ctx)
}

// Check runs the full check suite.
func (m *Ci) Check(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	// Per-check wall-times, filled by timedCheck. Printed as a table at the end
	// (and on failure) so every run's log shows which check dominated — the
	// attribution neither GitHub's single "Run Full Check Suite" step nor the
	// unlabeled Dagger exec spans can give. See timedCheck's doc comment.
	var timingsMu sync.Mutex
	var timings []checkTiming

	// Run cheap structural checks in parallel for faster fail detection.
	var fastEg errgroup.Group
	fastEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "structural", "hygiene", func() error {
			_, err := m.CheckHygiene(ctx)
			return err
		})
	})
	fastEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "structural", "layers", func() error {
			_, err := m.CheckLayers(ctx)
			return err
		})
	})
	fastEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "structural", "duplication", func() error {
			_, err := m.Duplication(ctx)
			return err
		})
	})
	fastEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "structural", "goformat", func() error {
			_, err := m.CheckGoFormat(ctx)
			return err
		})
	})
	if err := fastEg.Wait(); err != nil {
		fmt.Println(formatCheckTimings(timings))
		return "", err
	}

	// Run the fast analysis checks (format, analyze, generated-code) in
	// parallel — they share the setup base and are quick. Coverage is
	// deliberately NOT here: it runs the unit+widget suite (minutes), so
	// grouping it with format/analyze would make a one-line lint error wait on
	// it. Keeping this phase fast means such errors fail here (~1-2 min cold)
	// before the heavy phase below ever starts (fail-fast, #729).
	var analyze, mocks string
	var checkEg errgroup.Group
	checkEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "analysis", "format", func() error {
			setup := m.setup(m.checkSrc())
			_, err := setup.WithExec([]string{"dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"}).Stdout(ctx)
			return err
		})
	})
	checkEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "analysis", "analyze", func() error {
			setup := m.setup(m.checkSrc())
			var err error
			analyze, err = setup.WithExec([]string{"dart", "analyze", "--fatal-infos"}).Stdout(ctx)
			return err
		})
	})
	checkEg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "analysis", "generated", func() error {
			var err error
			mocks, err = m.CheckGenerated(ctx)
			return err
		})
	})
	if err := checkEg.Wait(); err != nil {
		fmt.Println(formatCheckTimings(timings))
		return "", err
	}

	// Heavy phase: coverage (unit+widget under coverage) plus the backend and
	// integration suites, all in parallel. It runs only after every fast check
	// above has passed. Coverage lives here rather than in its own earlier
	// phase so it overlaps the test suites instead of running before them —
	// removing a whole test-phase of wall-time from a passing run.
	// errgroup.Group (not WithContext) so a failing test does not cancel its
	// sibling via context — which would surface as "context canceled" in dagger
	// output and trigger spurious retries in check-dagger.
	var coverage, testBackend, testIntegration string
	var eg errgroup.Group
	eg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "tests", "coverage", func() error {
			var e error
			coverage, e = m.Coverage(ctx)
			return e
		})
	})
	eg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "tests", "backend", func() error {
			var e error
			testBackend, e = m.TestBackend(ctx)
			return e
		})
	})
	eg.Go(func() error {
		return timedCheck(&timingsMu, &timings, "tests", "integration", func() error {
			var e error
			testIntegration, e = m.TestIntegration(ctx)
			return e
		})
	})
	if err := eg.Wait(); err != nil {
		fmt.Println(formatCheckTimings(timings))
		return "", err
	}

	return fmt.Sprintf("All checks passed!\n%s\nAnalysis:\n%s\n\n%s\n\n%s\n\nBackend Tests:\n%s\n\nIntegration Tests:\n%s\n", formatCheckTimings(timings), analyze, mocks, coverage, testBackend, testIntegration), nil
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

	// Reuse the Deployer container so the SSH key is owned by (and readable
	// as) the unprivileged "deploy" user and CRLF-normalised — exactly like
	// the upload path. A hand-rolled container that mounts the key root-owned
	// 0600 leaves it unreadable by "deploy", so every `ssh … find` in the
	// script fails, list_remote_files() returns [] and the page silently
	// renders "No builds yet" even though artifacts are on the server.
	// Deployer is alpine with python3 + openssh-client already installed.
	return m.Deployer(sshKey, knownHosts).
		WithEnvVariable("SSH_USER", sshUser).
		WithEnvVariable("SSH_HOST", sshHost).
		WithDirectory("/src", scriptSource, dagger.ContainerWithDirectoryOpts{Owner: "deploy"}).
		WithWorkdir("/src").
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

// buildLinuxBundle builds the Linux release bundle.
//
// releaseVersion is the CalVer of the release this bundle belongs to. It is
// what update_service.dart uses to decide it must compare against GitHub
// Releases instead of latest.json (a git hash) — see PackageLinuxRelease.
//
// buildNumber is the same auto-incrementing number the Android path uses (the
// commit timestamp). Without it `flutter build linux` produces a bundle whose
// version.json carries no build number at all, so the About page shows a bare
// "0.1.1+" on desktop while Android shows "0.1.1+1790…".
//
// DeployLinux and PackageLinuxRelease pass identical arguments for the same
// commit, so the (expensive) Flutter build happens once and Dagger serves the
// second caller from cache — the hourly snapshot tarball and the release asset
// are then literally the same build.
func (m *Ci) buildLinuxBundle(commitHash, releaseVersion, buildNumber string) *dagger.Directory {
	args := []string{"flutter", "build", "linux", "--release"}
	if buildNumber != "" {
		args = append(args, "--build-number", buildNumber)
	}
	if commitHash != "" {
		args = append(args, "--dart-define=GIT_HASH="+commitHash)
	}
	if releaseVersion != "" {
		args = append(args, "--dart-define=RELEASE_VERSION="+releaseVersion)
	}
	return m.setup(m.linuxSrc()).
		WithExec(args).
		Directory("build/linux/x64/release/bundle")
}

// BuildLinuxRelease builds the Linux release bundle.
func (m *Ci) BuildLinuxRelease(
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
	// CalVer of the release this commit is published as (scripts/release_version.sh).
	// +optional
	releaseVersion string,
	// Auto-incrementing build number — the commit timestamp, as on Android.
	// +optional
	buildNumber string,
) *dagger.Directory {
	return m.buildLinuxBundle(commitHash, releaseVersion, buildNumber)
}

// DeployLinux packages and deploys the Linux release to the server.
func (m *Ci) DeployLinux(
	ctx context.Context,
	sshKey *dagger.Secret,
	knownHosts *dagger.Secret,
	sshUser string,
	sshHost string,
	commitHash string,
	// CalVer of the release cut from this same commit. Passing it here (rather
	// than building a second, subtly different bundle for the release) means
	// the snapshot tarball and the GitHub Release asset come from one build.
	// +optional
	releaseVersion string,
	// Auto-incrementing build number — the commit timestamp, as on Android.
	// +optional
	buildNumber string,
) (string, error) {
	bundle := m.buildLinuxBundle(commitHash, releaseVersion, buildNumber)

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

// defaultRepository is the GitHub repo that hosts the Releases mise installs
// from. Overridable on the release/check functions so a fork can test the whole
// flow against its own repo.
const defaultRepository = "guettli/sharedinbox"

// linuxReleaseDirName is the single top-level directory inside the release
// tarball. mise extracts the whole archive, so `strip_components = 1` lands the
// executable next to its `data/` and `lib/` siblings — which the Flutter Linux
// runner requires, because it resolves asset paths relative to /proc/self/exe.
func linuxReleaseDirName(version string) string {
	return fmt.Sprintf("sharedinbox-%s-linux-x86_64", version)
}

// PackageLinuxRelease builds the Linux bundle and packs it into the tarball
// that gets attached to a GitHub Release.
//
// The asset name carries "linux" and "x86_64" so mise's os/arch autodetection
// matches it even once an aarch64 asset exists alongside it.
//
// Layout (one top-level dir, see linuxReleaseDirName):
//
//	sharedinbox-<version>-linux-x86_64/
//	  sharedinbox                              # ELF executable
//	  sharedinbox.png                          # icon, installed by linux/CMakeLists.txt
//	  data/                                    # flutter_assets, icudtl.dat
//	  lib/                                     # libapp.so, libflutter_linux_gtk.so, …
//	  share/applications/sharedinbox.desktop   # menu entry (opt-in, see README)
func (m *Ci) PackageLinuxRelease(
	// CalVer release version without the leading "v", from
	// scripts/release_version.sh, e.g. "2026.9.29.2013".
	version string,
	// Git commit hash injected as GIT_HASH dart-define so the About page can display it.
	// +optional
	commitHash string,
	// Auto-incrementing build number — the commit timestamp, as on Android.
	// +optional
	buildNumber string,
) *dagger.File {
	dir := linuxReleaseDirName(version)
	asset := dir + ".tar.gz"
	return dag.Container().
		From("alpine:3.21").
		// GNU tar: busybox tar has no --sort/--mtime/--owner.
		WithExec([]string{"apk", "add", "--no-cache", "tar"}).
		WithDirectory("/pkg/"+dir, m.buildLinuxBundle(commitHash, version, buildNumber)).
		// The icon is already at the bundle root (linux/CMakeLists.txt installs
		// it there), so only the .desktop file has to be added.
		WithFile("/pkg/"+dir+"/share/applications/sharedinbox.desktop",
			m.Source.File("linux/packaging/sharedinbox.desktop")).
		// --sort=name + a fixed mtime keep the tarball byte-identical across
		// rebuilds of the same bundle, so re-running a release does not churn
		// the published SHA256SUMS.
		WithExec([]string{"tar", "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner",
			"-czf", "/tmp/" + asset, "-C", "/pkg", dir}).
		File("/tmp/" + asset)
}

// releaseLinuxScript publishes the tarball + checksums to the GitHub Release
// for tag v$VERSION, creating the release when it does not exist yet.
//
// The release must not be a draft: mise's github backend enumerates published
// releases only, so a draft is invisible to `mise use …@latest`.
const releaseLinuxScript = `#!/bin/sh
set -eu
TAG="v${VERSION}"
cd /out
sha256sum "${ASSET}" > SHA256SUMS
cat SHA256SUMS
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG exists — uploading assets"
    gh release upload "$TAG" "${ASSET}" SHA256SUMS --repo "$REPO" --clobber
else
    echo "Creating release $TAG"
    set -- "$TAG" "${ASSET}" SHA256SUMS --repo "$REPO" --title "$TAG" --generate-notes
    # --target names the commit GitHub creates the tag from, and it only has an
    # effect when the tag does not exist on the remote yet (the workflow_dispatch
    # path); on a tag-triggered run GitHub ignores it. It must be a FULL SHA,
    # branch or tag — the API rejects an abbreviated hash.
    [ -n "${TARGET_COMMIT:-}" ] && set -- "$@" --target "$TARGET_COMMIT"
    gh release create "$@"
fi
# Fail loudly if the asset did not actually land — mise resolving @latest to a
# release without a matching asset is the failure this guards against.
ASSETS=$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')
printf '%s\n' "$ASSETS" | grep -qxF "${ASSET}" || {
    echo "ERROR: ${ASSET} missing from release $TAG. Assets: $ASSETS"; exit 1; }
DRAFT=$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft')
[ "$DRAFT" = "false" ] || { echo "ERROR: release $TAG is a draft — mise cannot see it"; exit 1; }
echo "Published $TAG with ${ASSET} and SHA256SUMS"

# Releases are cut automatically from every Linux deploy, so without a
# retention bound the 16 MB assets pile up forever.
#
# A release must satisfy BOTH bounds to be deleted: outside the newest
# KEEP_RELEASES *and* older than KEEP_DAYS. Count alone is not safe. mise hides
# releases younger than minimum_release_age (24h by default) from "@latest", so
# if hourly deploys produced 20 releases inside a day, a keep-newest-20 rule
# would delete every release old enough to be eligible and "@latest" would
# resolve to nothing at all — a total install failure, not a stale version.
#
# The tag filter is a safety belt, not a nicety: only CalVer tags this script
# creates are eligible, so the hand-made v0.0.x tags — and anything else a
# human tagged — can never be deleted here.
if [ "${KEEP_RELEASES:-0}" -gt 0 ]; then
    CUTOFF=$(( $(date -u +%s) - ${KEEP_DAYS:-30} * 86400 ))
    # gh lists newest first. fromdateiso8601 avoids parsing dates in busybox.
    gh release list --repo "$REPO" --limit 200 --json tagName,createdAt \
        --jq '.[] | select(.tagName | test("^v[0-9]{4}(\\.[0-9]+){3}$"))
              | "\(.tagName) \(.createdAt | fromdateiso8601)"' > /tmp/releases.txt
    PRUNED=0
    INDEX=0
    while read -r old created; do
        [ -n "$old" ] || continue
        INDEX=$((INDEX + 1))
        [ "$INDEX" -le "${KEEP_RELEASES}" ] && continue
        [ "$created" -ge "$CUTOFF" ] && continue
        [ "$old" = "$TAG" ] && continue
        echo "  deleting $old (outside newest ${KEEP_RELEASES} and older than ${KEEP_DAYS:-30}d)"
        gh release delete "$old" --repo "$REPO" --yes --cleanup-tag || \
            echo "  WARN: could not delete $old"
        PRUNED=$((PRUNED + 1))
    done < /tmp/releases.txt
    echo "Pruned ${PRUNED} release(s); $(wc -l < /tmp/releases.txt) CalVer release(s) existed."
fi
`

// ReleaseLinux packages the Linux bundle and publishes it as a GitHub Release
// asset, so `mise use -g github:guettli/sharedinbox@<version>` can install it.
//
// This is additive: the hourly sharedinbox.de/builds + latest.json channel
// (DeployLinux) is untouched.
func (m *Ci) ReleaseLinux(
	ctx context.Context,
	// Needs contents:write on the repository.
	githubToken *dagger.Secret,
	// CalVer release version without the leading "v", from
	// scripts/release_version.sh. Tag is "v$version".
	version string,
	// Short git commit hash, injected as the GIT_HASH dart-define.
	// +optional
	commitHash string,
	// Auto-incrementing build number — the commit timestamp, as on Android.
	// +optional
	buildNumber string,
	// How many CalVer releases to keep regardless of age. 0 disables pruning.
	// +optional
	keepReleases int,
	// Minimum age in days before a release outside keepReleases may be
	// deleted. Both bounds must be satisfied — see the prune block in
	// releaseLinuxScript for why a count alone can break "@latest".
	// +optional
	keepDays int,
	// Full commit SHA the tag is created from on the workflow_dispatch path.
	// Must not be abbreviated — the Releases API rejects a short hash.
	// +optional
	targetCommit string,
	// owner/repo to release into. Defaults to guettli/sharedinbox.
	// +optional
	repository string,
	// cacheBuster forces the publish to re-run instead of returning a cached
	// result. Without it a second run for the same version replays the first
	// run's stdout — including its "asset landed" assertion — without ever
	// talking to GitHub, so a re-release after fixing a broken asset would be a
	// silent no-op (same hazard as FetchPlayStoreApks, see #432).
	// +optional
	cacheBuster string,
) (string, error) {
	if repository == "" {
		repository = defaultRepository
	}
	asset := linuxReleaseDirName(version) + ".tar.gz"

	return dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "add", "--no-cache", "github-cli"}).
		WithFile("/out/"+asset, m.PackageLinuxRelease(version, commitHash, buildNumber)).
		WithSecretVariable("GH_TOKEN", githubToken).
		WithEnvVariable("VERSION", version).
		WithEnvVariable("ASSET", asset).
		WithEnvVariable("REPO", repository).
		WithEnvVariable("TARGET_COMMIT", targetCommit).
		WithEnvVariable("KEEP_RELEASES", fmt.Sprintf("%d", keepReleases)).
		WithEnvVariable("KEEP_DAYS", fmt.Sprintf("%d", keepDays)).
		WithEnvVariable("RELEASE_CACHE_BUSTER", cacheBuster).
		WithNewFile("/tmp/release.sh", releaseLinuxScript).
		WithExec([]string{"sh", "/tmp/release.sh"}).
		Stdout(ctx)
}

// checkMiseInstallScript installs the published release through mise exactly
// the way the README tells users to, then proves the result actually runs.
//
// The launch test is the point of the whole check: a wrong strip_components /
// bin_path lands `sharedinbox` without its sibling data/ and lib/, which no
// amount of `command -v` checking would catch — the binary exists and then dies
// on startup.
const checkMiseInstallScript = `#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export MISE_YES=1

curl -fsSL https://mise.run | sh
mise --version

mkdir -p "$HOME/.config/mise"
# The snippet documented in README.md, with the version pinned to the release
# under test instead of "latest" — if the option names drift, the docs lie.
cat > "$HOME/.config/mise/config.toml" <<EOF
[tools."github:${REPO}"]
version = "${VERSION}"
asset_pattern = "sharedinbox-*-linux-x86_64.tar.gz"
strip_components = 1
bin_path = "."
filter_bins = ["sharedinbox"]
EOF
cat "$HOME/.config/mise/config.toml"

mise install
SHIM=$(mise which sharedinbox)
echo "mise which: $SHIM"

# filter_bins makes mise expose the tool through a symlink farm
# (<install>/.mise-bins/sharedinbox -> <install>/./sharedinbox), and
# 'mise which' returns the symlink. Resolve it before looking for the bundle's
# data/ and lib/, which sit next to the REAL binary. The app itself is fine
# either way — the Flutter runner resolves asset paths through
# /proc/self/exe, which follows symlinks — so checking the symlink's own
# directory would fail a release that works perfectly.
BIN=$(readlink -f "$SHIM")
echo "resolved: $BIN"
case "$BIN" in
    */mise/installs/*) ;;
    *) echo "ERROR: sharedinbox did not resolve into a mise install dir: $BIN"; exit 1 ;;
esac
[ -x "$BIN" ] || { echo "ERROR: $BIN is not executable"; exit 1; }

INSTALL_DIR=$(dirname "$BIN")
for required in data/flutter_assets lib/libapp.so; do
    [ -e "$INSTALL_DIR/$required" ] || {
        echo "ERROR: $required missing next to the executable — tarball layout or strip_components is wrong"
        ls -la "$INSTALL_DIR"; exit 1; }
done

# assets/changelog.txt is generated from git history before the Dagger build
# (task generate-changelog). When that step is missing the bundle still builds
# and launches perfectly — only the ChangeLog screen breaks at runtime with
# 'Unable to load asset'. Nothing else would catch it, so assert it here.
CHANGELOG="$INSTALL_DIR/data/flutter_assets/assets/changelog.txt"
if [ ! -s "$CHANGELOG" ]; then
    echo "ERROR: assets/changelog.txt missing or empty in the bundle — the build"
    echo "       ran without 'task generate-changelog', so the ChangeLog screen is broken."
    ls -la "$INSTALL_DIR/data/flutter_assets/assets/" 2>&1 || true
    exit 1
fi
echo "OK: changelog asset present ($(wc -l < "$CHANGELOG") entries)"

# A missing runtime .so shows up here rather than as a mystery launch failure.
# The plugin libraries in lib/ pull in their own dependencies (libsecret,
# jsoncpp, …), so check them too rather than only the executable.
#
# Collected into a variable first: under 'set -o pipefail' a non-ELF file in
# lib/ makes ldd exit non-zero, which would fail the pipeline and report
# "unresolved libraries" with no matching lines to show for it.
#
# LD_LIBRARY_PATH is required for the lib/ pass: the plugin .so files link
# against libflutter_linux_gtk.so, their own sibling. Only the executable
# carries the $ORIGIN/lib RPATH, so ldd on a plugin in isolation reports
# "libflutter_linux_gtk.so => not found" for a library that is right there —
# which would fail every release. Verified against a real bundle.
LDD_OUT=$({ ldd "$BIN" || true; LD_LIBRARY_PATH="$INSTALL_DIR/lib" ldd "$INSTALL_DIR"/lib/*.so || true; } 2>&1)
if printf '%s\n' "$LDD_OUT" | grep "not found"; then
    echo "ERROR: unresolved shared libraries (install the runtime deps listed in README.md)"
    exit 1
fi

echo "Launching under Xvfb…"
set +e
xvfb-run -a timeout 20 "$BIN" >/tmp/app.log 2>&1 &
APP=$!
sleep 12
if ! kill -0 "$APP" 2>/dev/null; then
    wait "$APP"; rc=$?
    echo "ERROR: sharedinbox exited after less than 12s (rc=$rc)"
    cat /tmp/app.log
    exit 1
fi
kill "$APP" 2>/dev/null
set -e
echo "--- app log ---"
cat /tmp/app.log || true
echo "OK: mise install of ${VERSION} launches and survives 12s"

# The upgrade command the in-app banner tells users to run (kMiseUpgradeCommand
# in lib/core/services/update_service.dart) must address the TOOL, not the bin.
# "mise up sharedinbox" matches no tool and exits 0 with "All tools are up to
# date", so a wrong name here is invisible unless it is asserted.
UP_OUT=$(mise up "github:${REPO}" 2>&1) || { echo "ERROR: mise up failed: $UP_OUT"; exit 1; }
printf '%s\n' "$UP_OUT"
case "$UP_OUT" in
    *"github:${REPO}"*|*"up to date"*) ;;
    *) echo "ERROR: 'mise up github:${REPO}' did not recognise the tool"; exit 1 ;;
esac
# The negative control: the bin name alone must NOT be what we document.
if mise up sharedinbox 2>&1 | grep -qi "sharedinbox@"; then
    echo "NOTE: 'mise up sharedinbox' now resolves the tool too — the docs could use the short form"
fi

# The bare "@latest" form is the one-liner in the README's TL;DR, and it is the
# command most users will actually run, so a real failure here must be loud.
#
# One failure is expected rather than broken: mise hides releases younger than
# minimum_release_age (24h by default) from "@latest", so a release published
# minutes ago is deliberately invisible. Distinguish that from everything else
# — an install that is merely young is fine, an unresolvable "@latest" is not.
rm -f "$HOME/.config/mise/config.toml"
if mise use -g "github:${REPO}@latest" >/tmp/bare.log 2>&1 && mise which sharedinbox >/dev/null 2>&1; then
    echo "OK: bare 'mise use -g github:${REPO}@latest' resolves sharedinbox"
elif grep -q "minimum_release_age" /tmp/bare.log; then
    echo "EXPECTED: '@latest' currently hides this release (mise minimum_release_age, 24h)."
    echo "          Users installing today must pin the version; @latest picks it up tomorrow."
    grep -o "eligible [^)]*" /tmp/bare.log | head -1 || true
else
    echo "ERROR: bare 'mise use -g github:${REPO}@latest' failed for an unexpected reason:"
    cat /tmp/bare.log || true
    exit 1
fi
`

// retractLinuxReleaseScript hides a release that failed verification.
//
// Converting it back to a draft is what removes it from mise: the github
// backend enumerates published releases only, so a draft is invisible to
// `@latest`. The tag and the assets survive for diagnosis.
const retractLinuxReleaseScript = `#!/bin/sh
set -eu
TAG="v${VERSION}"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$TAG" --repo "$REPO" --draft=true
    echo "Retracted $TAG — converted back to a draft, mise can no longer see it."
else
    echo "No release $TAG to retract (it was never created)."
fi
`

// RetractLinuxRelease converts a release back to a draft after a failed
// verification.
//
// This runs in a container rather than on the CI runner because the runner
// image ships no gh (arc-runner-image/Dockerfile installs only jq, python3,
// openssh-client, curl and git). An inline `gh release edit` on the runner
// fails with "command not found", and if that call is guarded by
// `gh release view … >/dev/null 2>&1` it silently reports "nothing to
// retract" — leaving a broken release public. That is exactly what happened
// on the first real release.
func (m *Ci) RetractLinuxRelease(
	ctx context.Context,
	// Needs contents:write on the repository.
	githubToken *dagger.Secret,
	// CalVer release version without the leading "v".
	version string,
	// owner/repo. Defaults to guettli/sharedinbox.
	// +optional
	repository string,
	// cacheBuster forces the retract to re-run instead of replaying a cached
	// result; without it a second attempt would report success without acting.
	// +optional
	cacheBuster string,
) (string, error) {
	if repository == "" {
		repository = defaultRepository
	}
	return dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "add", "--no-cache", "github-cli"}).
		WithSecretVariable("GH_TOKEN", githubToken).
		WithEnvVariable("VERSION", version).
		WithEnvVariable("REPO", repository).
		WithEnvVariable("RETRACT_CACHE_BUSTER", cacheBuster).
		WithNewFile("/tmp/retract.sh", retractLinuxReleaseScript).
		WithExec([]string{"sh", "/tmp/retract.sh"}).
		Stdout(ctx)
}

// GuiTestRelease drives the packaged release through its accessibility tree
// and asserts the app actually works — not merely that the process survives.
//
// The idea is not new here: SmokeTestRelease boots the signed APK on an
// emulator, and TestAndroidFirebase runs a robo crawl against the Play Store
// binary — both deliberately test what users install rather than a debug
// build. Two things were missing. Linux had no equivalent at all, and no test
// on any platform *asserts* anything about what the packaged app shows: the
// robo crawl hunts for crashes (FATAL EXCEPTION, "has died"), so a screen that
// renders an error message instead of its content passes.
//
// That is precisely how a release shipped with the ChangeLog screen broken
// (#932) while TestIntegration (a build of the working tree), CheckMiseInstall
// (does the process survive 12s?) and CI were all green.
//
// Driving through AT-SPI rather than pixels or OCR means the assertions are on
// exact strings, real roles and widget states — and that a control shipped
// without a semantic label fails the run, which makes this an accessibility
// test as well.
func (m *Ci) GuiTestRelease(
	ctx context.Context,
	// Release version to install, or "latest".
	version string,
	// owner/repo to install from. Defaults to guettli/sharedinbox.
	// +optional
	repository string,
	// Optional token, only to avoid anonymous GitHub API rate limits.
	// +optional
	githubToken *dagger.Secret,
	// cacheBuster forces the run instead of replaying a cached pass.
	// +optional
	cacheBuster string,
) (string, error) {
	if repository == "" {
		repository = defaultRepository
	}
	scripts := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/gui_driver.py", "scripts/gui_release_test.py",
			"scripts/gui_test_entrypoint.sh"},
	})

	ctr := dag.Container().
		From("ubuntu:24.04").
		WithEnvVariable("DEBIAN_FRONTEND", "noninteractive").
		WithExec([]string{"/bin/sh", "-c",
			"apt-get -qq update && apt-get install -y -qq --no-install-recommends " +
				"ca-certificates curl socat " +
				// the app's own runtime dependencies (README's apt line)
				"libgtk-3-0t64 libsecret-1-0 libgcrypt20 libjsoncpp25 zenity xdg-utils " +
				// virtual display + screenshots
				"xvfb xauth libosmesa6 libegl1 imagemagick x11-utils xdotool " +
				// accessibility: at-spi plus the GSettings machinery Flutter
				// consults before it will build a semantics tree at all
				"at-spi2-core python3-pyatspi python3-gi gir1.2-atspi-2.0 " +
				"dbus-x11 libglib2.0-bin gsettings-desktop-schemas dconf-service"}).
		WithExec([]string{"useradd", "-m", "-s", "/bin/bash", "tester"}).
		WithExec([]string{"install", "-d", "-o", "tester", "/shots"}).
		WithDirectory("/src", scripts, dagger.ContainerWithDirectoryOpts{Owner: "tester"}).
		WithUser("tester").
		WithEnvVariable("HOME", "/home/tester").
		WithEnvVariable("GUI_SHOT_DIR", "/shots").
		WithEnvVariable("RELEASE_VERSION", version).
		WithEnvVariable("GUI_CACHE_BUSTER", cacheBuster)

	// The secret has to go on BEFORE the install exec, not after: a Dagger
	// env/secret variable applies only to *subsequent* execs. Attached
	// afterwards it reaches the test entrypoint — which has no use for it —
	// while the mise install, release lookup, asset download and attestation
	// checks all run anonymously against a 60 req/hour-per-IP limit shared by
	// everything on the engine. The step then goes red for a reason that has
	// nothing to do with the release. CheckMiseInstall gets this ordering
	// right; this one did not.
	if githubToken != nil {
		ctr = ctr.WithSecretVariable("GITHUB_TOKEN", githubToken)
	}

	ctr = ctr.WithExec([]string{"/bin/sh", "-c",
		`set -e; export PATH="$HOME/.local/bin:$PATH"; ` +
			`curl -fsSL https://mise.run | sh >/dev/null; ` +
			`MISE_YES=1 mise use -g "github:` + repository + `@` + version + `"`})

	return m.WithStalwart(ctr).
		WithExec([]string{"bash", "/src/scripts/gui_test_entrypoint.sh"}).
		Stdout(ctx)
}

// CheckMiseInstall installs a published release with mise inside a clean
// Ubuntu container and asserts it launches. Needs the release to exist on
// GitHub and real network access, so it is deliberately NOT part of check-fast
// or the PR gate — .github/workflows/release.yml runs it right after publishing.
func (m *Ci) CheckMiseInstall(
	ctx context.Context,
	// Release version without the leading "v", or "latest".
	version string,
	// owner/repo to install from. Defaults to guettli/sharedinbox.
	// +optional
	repository string,
	// Optional token, only to avoid anonymous GitHub API rate limits
	// (60 requests/hour per IP, shared by everything on the Dagger engine).
	// +optional
	githubToken *dagger.Secret,
	// cacheBuster forces the check to re-run instead of replaying a cached
	// PASS. Without it, re-running the check for the same version after fixing
	// a broken release asset would report success without installing anything.
	// +optional
	cacheBuster string,
) (string, error) {
	if repository == "" {
		repository = defaultRepository
	}

	ctr := dag.Container().
		From("ubuntu:24.04").
		WithEnvVariable("DEBIAN_FRONTEND", "noninteractive").
		// Runtime dependencies only — deliberately NOT the -dev packages the
		// build image installs. This container is the proof that the README's
		// apt line is sufficient for a user who only ever installs via mise.
		WithExec([]string{"/bin/sh", "-c",
			"apt-get -qq update && apt-get install -y -qq --no-install-recommends " +
				"ca-certificates curl git " +
				// README runtime deps. libjsoncpp25 is Ubuntu 24.04's name for
				// the jsoncpp the flutter_secure_storage plugin links against.
				"libgtk-3-0t64 libsecret-1-0 libgcrypt20 libjsoncpp25 zenity xdg-utils " +
				// headless GL so the GTK window can be created under Xvfb.
				// xauth is what xvfb-run needs and is only a Recommends of xvfb.
				"xvfb xauth libosmesa6 libegl1"}).
		WithExec([]string{"useradd", "-m", "-s", "/bin/bash", "tester"}).
		WithUser("tester").
		WithEnvVariable("HOME", "/home/tester").
		WithEnvVariable("LIBGL_ALWAYS_SOFTWARE", "1").
		WithEnvVariable("VERSION", version).
		WithEnvVariable("REPO", repository).
		WithEnvVariable("MISE_CHECK_CACHE_BUSTER", cacheBuster)
	if githubToken != nil {
		// mise reads GITHUB_TOKEN for its GitHub API calls.
		ctr = ctr.WithSecretVariable("GITHUB_TOKEN", githubToken)
	}
	return ctr.
		WithNewFile("/tmp/check_mise_install.sh", checkMiseInstallScript).
		WithExec([]string{"bash", "/tmp/check_mise_install.sh"}).
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
//
// The Firebase project ID is read from the service account JSON's project_id
// field so callers do not need to plumb it separately (the SA can only target
// the project that issued it anyway).
func (m *Ci) TestAndroidFirebase(
	ctx context.Context,
	// Directory containing the Play Store split APKs. Must include a
	// base-master.apk; everything else is forwarded as --additional-apks.
	apks *dagger.Directory,
	serviceAccountKey *dagger.Secret,
) (string, error) {
	return dag.Container().
		From("google/cloud-sdk:slim").
		WithDirectory("/apks", apks).
		WithSecretVariable("FIREBASE_SA_KEY", serviceAccountKey).
		WithUser("cloudsdk").
		WithExec([]string{"/bin/bash", "-c",
			`auth_err=$(mktemp); trap 'rm -f "$auth_err"' EXIT; \
			 gcloud auth activate-service-account --key-file=<(echo "$FIREBASE_SA_KEY") 2>"$auth_err" \
			   || { cat "$auth_err"; exit 1; }; \
			 FIREBASE_PROJECT_ID=$(python3 -c 'import json,os; print(json.loads(os.environ["FIREBASE_SA_KEY"])["project_id"])') \
			   || { echo "ERROR: could not extract project_id from FIREBASE_SA_KEY"; exit 1; }; \
			 [ -n "$FIREBASE_PROJECT_ID" ] || { echo "ERROR: project_id missing from FIREBASE_SA_KEY"; exit 1; }; \
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

// smokeTestScript drives the emulator inside the SmokeTestRelease container. It
// is kept as a file (rather than an inline `-c` string) to avoid nested-quote
// fragility and because it runs via `su ci` — the emulator refuses to run as
// root and the AVD lives in ci's HOME. It boots the AVD cold, waits for a full
// boot, installs the release APK, launches MainActivity and fails if the app
// crashes (FATAL EXCEPTION / process death) or is not running after launch.
const smokeTestScript = `#!/usr/bin/env bash
set -euo pipefail
export HOME=/home/ci
export ANDROID_HOME="${ANDROID_HOME:?ANDROID_HOME not set}"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin"
PACKAGE="de.sharedinbox.mua"

echo "Booting KVM-accelerated emulator (cold)…"
emulator -avd smoke -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -accel on -netdelay none -netspeed full \
    > /tmp/emulator.log 2>&1 &
EMU_PID=$!

for _i in $(seq 1 60); do
    adb get-state 2>/dev/null | grep -q device && break
    kill -0 "$EMU_PID" 2>/dev/null || { echo "ERROR: emulator exited early"; tail -50 /tmp/emulator.log; exit 1; }
    sleep 2
done
adb wait-for-device

BOOT=0
for _i in $(seq 1 90); do
    BOOT=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ "$BOOT" = "1" ] && break
    kill -0 "$EMU_PID" 2>/dev/null || { echo "ERROR: emulator exited during boot"; tail -50 /tmp/emulator.log; exit 1; }
    sleep 2
done
[ "$BOOT" = "1" ] || { echo "ERROR: Android boot did not complete in time"; tail -50 /tmp/emulator.log; exit 1; }
echo "Emulator booted."

echo "Installing release APK…"
adb install -r /tmp/app-release.apk

echo "Clearing crash logcat buffer…"
adb logcat -b crash -c

echo "Launching $PACKAGE/.MainActivity…"
adb shell am start -W -n "$PACKAGE/.MainActivity"

WATCH=20
echo "Watching crash logcat for ${WATCH}s…"
sleep "$WATCH"
crash_rc=0
CRASH=$(adb logcat -b crash -d 2>&1) || crash_rc=$?
[ "$crash_rc" -eq 0 ] || { echo "ERROR: adb logcat -b crash -d failed (rc=$crash_rc): $CRASH"; exit 1; }
if echo "$CRASH" | grep -qE "FATAL EXCEPTION|Process .* has died"; then
    echo "----- CRASH DETECTED -----"
    echo "$CRASH"
    echo "--------------------------"
    exit 1
fi
# Belt-and-suspenders: a launch crash kills the process even if the crash
# buffer detection above misses it. NoClassDefFoundError lands here.
if ! adb shell pidof "$PACKAGE" >/dev/null 2>&1; then
    echo "ERROR: $PACKAGE is not running ${WATCH}s after launch — it crashed on startup."
    echo "--- crash buffer ---"; echo "$CRASH"
    echo "--- last main log ---"; adb logcat -d -t 200 2>/dev/null | grep -iE "$PACKAGE|AndroidRuntime|NoClassDefFound|flutter" || true
    exit 1
fi
echo "OK — $PACKAGE launched and survived ${WATCH}s with no crash signal."
`

// SmokeTestRelease boots the signed release APK on a KVM-accelerated, headless
// emulator inside Dagger and fails if the app crashes on launch. This catches
// the class of release-only crashes — R8 stripping, NoClassDefFoundError from
// compileOnly libraries — that debug builds and `flutter build` never exercise,
// which is exactly how a crashing build reached Play Store (#99, root cause #100).
//
// It must run on a Dagger engine that has /dev/kvm (the p16 bare-metal engine):
// the cloud ARC runners have no KVM, so pure software emulation is unusably slow.
// The emulator exec uses InsecureRootCapabilities so the container can open
// /dev/kvm — the #99 spike confirmed KVM_GET_API_VERSION works there with no
// engine config change. The release APK is built with the same R8/minify config
// as the shipped artifact (via BuildAndroidApk), so it reproduces the crash.
func (m *Ci) SmokeTestRelease(
	ctx context.Context,
	keystoreBase64 *dagger.Secret,
	keystorePassword *dagger.Secret,
	// Git commit hash injected as GIT_HASH dart-define (matches BuildAndroidApk).
	// +optional
	commitHash string,
) (string, error) {
	apk := m.BuildAndroidApk(keystoreBase64, keystorePassword, "1", commitHash)
	return m.emulatorBase().
		WithFile("/tmp/app-release.apk", apk).
		WithNewFile("/tmp/smoke.sh", smokeTestScript).
		WithUser("root").
		WithExec([]string{"/bin/bash", "-c",
			`[ -e /dev/kvm ] || { echo "ERROR: /dev/kvm absent — SmokeTestRelease must run on the p16 KVM engine"; exit 1; }; ` +
				`chmod 0666 /dev/kvm; chown ci /dev/kvm 2>/dev/null || true; ` +
				`exec su ci -c "ANDROID_HOME=$ANDROID_HOME bash /tmp/smoke.sh"`},
			dagger.ContainerWithExecOpts{InsecureRootCapabilities: true}).
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
// APKs and a "versionCode" text file with the resolved alpha versionCode.
// When Play has not finished generating split APKs, the returned directory
// contains a "PENDING" marker (and "versionCode") instead of APKs — the
// wrapper (scripts/run_firebase_test.sh) reads the marker and skips the
// Firebase Test Lab attempt with a ::notice::. Any other failure (auth,
// network, Play API 5xx) still propagates and fails loudly. See #414 for why
// we no longer treat Play-side delay as a red build. Runs in a Python
// container so the runner host does not need google-auth / requests installed
// (matches the UploadToPlayStore pattern).
//
// Each exec does exactly ONE Play readiness check (PLAY_APKS_POLL_TIMEOUT_SECONDS=0)
// and returns immediately — ready → download the APKs, not ready → drop a
// PENDING marker. The long-horizon waiting lives entirely in the wrapper's
// retry loop, which re-checks across fresh execs. Polling inside the exec would
// hold the shared Dagger engine idle for the whole generation window (which can
// exceed an hour) on top of the wrapper's own sleep — engine time reclaimed for
// a wait that does not need the engine (see #657, #432).
func (m *Ci) FetchPlayStoreApks(
	playStoreConfig *dagger.Secret,
	// cacheBuster forces the fetch to re-run instead of returning a cached
	// result. The wrapper (scripts/run_firebase_test.sh) now polls Play by
	// retrying this fetch across fresh short execs and passes a distinct value
	// per attempt, so each attempt actually re-checks Play for freshly
	// generated split APKs — a cached PENDING directory would otherwise make
	// the retry loop a silent no-op (see #432).
	// +optional
	cacheBuster string,
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
		// One Play readiness check per exec, then return (ready → download,
		// not ready → PENDING). The wrapper's retry loop owns the waiting, so
		// the engine is never held idle polling Play (see #657).
		WithEnvVariable("PLAY_APKS_POLL_TIMEOUT_SECONDS", "0").
		// Changing env var busts the exec cache key so each retry re-runs.
		WithEnvVariable("FETCH_CACHE_BUSTER", cacheBuster).
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

// Renovate runs Renovate bot against the repository on GitHub.
func (m *Ci) Renovate(
	ctx context.Context,
	// githubToken authenticates Renovate against the GitHub platform.
	githubToken *dagger.Secret,
) (string, error) {
	return dag.Container().
		From("renovate/renovate:43").
		WithSecretVariable("RENOVATE_TOKEN", githubToken).
		WithEnvVariable("RENOVATE_PLATFORM", "github").
		WithEnvVariable("RENOVATE_REPOSITORIES", "guettli/sharedinbox").
		WithEnvVariable("LOG_LEVEL", "info").
		WithUser("ubuntu").
		WithExec([]string{"renovate"}).
		Stdout(ctx)
}

// PrintRunnerWait prints how long the workflow job waited in the runner
// queue before this step started, by reading the run's created_at via the
// GitHub API. Replaces scripts/print_runner_wait.sh so workflows can invoke
// the same logic through Dagger.
func (m *Ci) PrintRunnerWait(
	ctx context.Context,
	githubToken *dagger.Secret,
	// apiUrl typically $GITHUB_API_URL (e.g. https://api.github.com).
	apiUrl string,
	// repository typically $GITHUB_REPOSITORY ("owner/repo").
	repository string,
	// runId typically $GITHUB_RUN_ID.
	runId string,
) (string, error) {
	const script = `#!/bin/sh
set -u
runner_start=$(date +%s)
response=$(curl -sf --max-time 30 \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL:-https://api.github.com}/repos/${REPOSITORY:-}/actions/runs/${RUN_ID:-}")
curl_rc=$?
if [ "$curl_rc" -ne 0 ]; then
    echo "Runner wait time: unknown (API lookup failed, curl exit $curl_rc)"
    exit 0
fi
created=$(printf '%s' "$response" | python3 -c "import sys,json;print(json.load(sys.stdin).get('created_at',''))")
py_rc=$?
if [ "$py_rc" -ne 0 ]; then
    echo "Runner wait time: unknown (malformed JSON from GitHub API, python exit $py_rc)" >&2
    exit 1
fi
if [ -n "$created" ]; then
    queued_epoch=$(date -d "$created" +%s)
    echo "Runner wait time: $((runner_start - queued_epoch))s (queued at $created)"
else
    echo "Runner wait time: unknown (created_at missing from response)"
fi
`
	return dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"apk", "add", "--no-cache", "curl", "coreutils"}).
		WithNewFile("/tmp/print_runner_wait.sh", script).
		WithSecretVariable("GITHUB_TOKEN", githubToken).
		WithEnvVariable("API_URL", apiUrl).
		WithEnvVariable("REPOSITORY", repository).
		WithEnvVariable("RUN_ID", runId).
		WithUser("nobody").
		WithExec([]string{"sh", "/tmp/print_runner_wait.sh"}).
		Stdout(ctx)
}

// ChangedTargets resolves which deploy targets need to run based on the
// changed files since the last successful run of a specific workflow job.
// Wraps scripts/changed_targets.py so deploy.yml / website.yml can replace
// their inline Python with a single Dagger invocation. The script prints
// notice/warning lines to stderr and the JSON verdict on stdout.
func (m *Ci) ChangedTargets(
	ctx context.Context,
	githubToken *dagger.Secret,
	apiUrl string,
	repository string,
	headSha string,
	eventName string,
	workflowFile string,
	jobName string,
	// targets is a JSON object mapping target name to path regex, e.g.
	// {"android":"^(android/|lib/|...)","linux":"^(linux/|lib/|...)"}.
	targets string,
	// alwaysOnNonSchedule when "true" treats any non-"schedule" event as
	// "deploy everything" (matches the historical website.yml behaviour).
	// +optional
	alwaysOnNonSchedule string,
) (string, error) {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/changed_targets.py"},
	})

	container := dag.Container().
		From("python:3.12-alpine").
		WithFile("/src/scripts/changed_targets.py", scriptSource.File("scripts/changed_targets.py")).
		WithSecretVariable("GITHUB_TOKEN", githubToken).
		WithEnvVariable("GITHUB_API_URL", apiUrl).
		WithEnvVariable("GITHUB_REPOSITORY", repository).
		WithEnvVariable("HEAD_SHA", headSha).
		WithEnvVariable("EVENT_NAME", eventName).
		WithEnvVariable("WORKFLOW_FILE", workflowFile).
		WithEnvVariable("JOB_NAME", jobName).
		WithEnvVariable("TARGETS", targets).
		WithWorkdir("/src")
	if alwaysOnNonSchedule != "" {
		container = container.WithEnvVariable("ALWAYS_ON_NON_SCHEDULE", alwaysOnNonSchedule)
	}
	return container.
		WithUser("nobody").
		WithExec([]string{"python3", "scripts/changed_targets.py"}).
		Stdout(ctx)
}

// PublishDevContainer builds Dockerfile.dev inside Dagger and pushes it to
// the given image reference under both :latest and :<short-sha> tags.
// Replaces the docker login + docker build + docker push steps in
// publish-dev-container.yml so the workflow runs entirely through Dagger.
// The build context is the repo root (Dockerfile.dev COPYs files from
// several directories), supplied by +defaultPath="..".
func (m *Ci) PublishDevContainer(
	ctx context.Context,
	// buildContext is the Docker build context. Defaults to the repo
	// root because the constructor's filtered Source omits Dockerfile.dev.
	// +defaultPath=".."
	buildContext *dagger.Directory,
	registryToken *dagger.Secret,
	registryUser string,
	// imageRef is the full image path without a tag,
	// e.g. ghcr.io/guettli/sharedinbox-dev.
	imageRef string,
	// commitSha is used to derive the :<short-sha> tag.
	commitSha string,
) (string, error) {
	short := commitSha
	if len(short) > 7 {
		short = short[:7]
	}

	// .daggerignore at the repo root keeps build/, cache dirs, etc. out
	// of the upload to the engine.
	built := buildContext.
		DockerBuild(dagger.DirectoryDockerBuildOpts{
			Dockerfile: "Dockerfile.dev",
		}).
		WithRegistryAuth(imageRef, registryUser, registryToken)

	if _, err := built.Publish(ctx, imageRef+":latest"); err != nil {
		return "", fmt.Errorf("publish :latest: %w", err)
	}
	digest, err := built.Publish(ctx, imageRef+":"+short)
	if err != nil {
		return "", fmt.Errorf("publish :%s: %w", short, err)
	}
	return fmt.Sprintf("Published %s:latest and %s:%s (%s)\n", imageRef, imageRef, short, digest), nil
}

// VerifyPlayStoreDeploy queries the Play Store alpha track and fails if the
// latest versionCode is older than one hour, which would mean the deploy
// silently did not land. Runs scripts/verify_playstore_deploy.py inside a
// Python container so the runner does not need google-auth / requests
// installed (mirrors the FetchPlayStoreApks / UploadToPlayStore pattern).
func (m *Ci) VerifyPlayStoreDeploy(
	ctx context.Context,
	playStoreConfig *dagger.Secret,
) (string, error) {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/verify_playstore_deploy.py"},
	})

	return dag.Container().
		From("python:3.12-alpine").
		WithMountedCache("/tmp/pip-cache", dag.CacheVolume("pip-cache")).
		WithExec([]string{"pip", "install", "--cache-dir", "/tmp/pip-cache", "google-auth", "requests"}).
		WithFile("/src/scripts/verify_playstore_deploy.py", scriptSource.File("scripts/verify_playstore_deploy.py")).
		WithSecretVariable("PLAY_STORE_CONFIG_JSON", playStoreConfig).
		WithWorkdir("/src").
		WithUser("nobody").
		WithExec([]string{"python3", "scripts/verify_playstore_deploy.py"}).
		Stdout(ctx)
}

// WebsiteVerify hits the public site and confirms that the expected git
// commit hash is live, retrying for ~60s. Optionally tunnels the curl
// through SSH so the check runs from the web host itself (useful when the
// caller's public network egress is blocked). Replaces scripts/website-verify.sh.
func (m *Ci) WebsiteVerify(
	ctx context.Context,
	commitHash string,
	// +optional
	sshKey *dagger.Secret,
	// +optional
	knownHosts *dagger.Secret,
	// +optional
	sshUser string,
	// +optional
	sshHost string,
) (string, error) {
	useSSH := sshKey != nil && knownHosts != nil && sshUser != "" && sshHost != ""

	verifyScript := `#!/bin/sh
set -u
VERSION="$1"
URL="https://sharedinbox.de/"
USE_SSH="${USE_SSH:-false}"
echo "Checking that version ${VERSION} is live at ${URL} ..."
for i in 1 2 3 4 5 6; do
    if [ "$USE_SSH" = "true" ]; then
        # Run remote curl under 'set -e' so a network error propagates as a
        # non-zero ssh exit — distinct from HTTP != 200.
        OUT=$(ssh -i /home/deploy/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "
            set -e
            HTTP=\$(curl -so /tmp/website-verify.html -w '%{http_code}' '${URL}')
            echo \"\$HTTP\"
            cat /tmp/website-verify.html
        ")
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "FAIL: ssh/curl network error (exit $rc) at attempt ${i}/6 for ${URL}"
            exit 1
        fi
        HTTP=$(echo "$OUT" | head -n 1)
        HTML=$(echo "$OUT" | tail -n +2)
    else
        HTTP=$(curl -so /tmp/website-verify.html -w "%{http_code}" "${URL}")
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "FAIL: curl network error (exit $rc) at attempt ${i}/6 for ${URL}"
            exit 1
        fi
        HTML=$(cat /tmp/website-verify.html)
    fi
    if [ "${HTTP}" != "200" ]; then
        echo "HTTP status ${HTTP} (attempt ${i}/6); waiting 10s ..."
    elif echo "$HTML" | grep -q "x-version.*${VERSION}"; then
        echo "OK: version ${VERSION} is live (HTTP ${HTTP})."
        exit 0
    else
        echo "HTTP 200 but version ${VERSION} not found (attempt ${i}/6); waiting 10s ..."
    fi
    sleep 10
done
echo "FAIL: version ${VERSION} not live at ${URL} after 60s"
exit 1
`

	if useSSH {
		// Reuse Deployer so the SSH key + known_hosts handling matches the
		// upload path. Deployer already includes openssh-client and python3
		// in an alpine image; add curl for the local-fallback case.
		container := m.Deployer(sshKey, knownHosts).
			WithUser("root").
			WithExec([]string{"apk", "add", "--no-cache", "curl"}).
			WithUser("deploy").
			WithEnvVariable("SSH_USER", sshUser).
			WithEnvVariable("SSH_HOST", sshHost).
			WithEnvVariable("USE_SSH", "true").
			WithNewFile("/tmp/verify.sh", verifyScript).
			WithExec([]string{"sh", "/tmp/verify.sh", commitHash})
		return container.Stdout(ctx)
	}

	return dag.Container().
		From("alpine:3.21").
		WithExec([]string{"apk", "add", "--no-cache", "curl"}).
		WithNewFile("/tmp/verify.sh", verifyScript).
		WithUser("nobody").
		WithExec([]string{"sh", "/tmp/verify.sh", commitHash}).
		Stdout(ctx)
}

// UpdateDeployHealthLabel sets CI/Full-Pass or CI/Full-Fail on the deploy
// health tracking issue. Replaces the inline Python in deploy.yml's
// label-deploy-health job so the workflow runs entirely through Dagger.
func (m *Ci) UpdateDeployHealthLabel(
	ctx context.Context,
	githubToken *dagger.Secret,
	issueNumber string,
	// allSucceeded "true" or "false". Anything other than "true" is treated
	// as failed.
	allSucceeded string,
	// +optional
	githubRepository string,
	// +optional
	githubApiUrl string,
) (string, error) {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/update_deploy_health_label.py"},
	})

	container := dag.Container().
		From("python:3.12-alpine").
		WithFile("/src/scripts/update_deploy_health_label.py", scriptSource.File("scripts/update_deploy_health_label.py")).
		WithSecretVariable("GITHUB_TOKEN", githubToken).
		WithEnvVariable("DEPLOY_HEALTH_ISSUE", issueNumber).
		WithEnvVariable("ALL_SUCCEEDED", allSucceeded).
		WithWorkdir("/src")
	if githubRepository != "" {
		container = container.WithEnvVariable("GITHUB_REPOSITORY", githubRepository)
	}
	if githubApiUrl != "" {
		container = container.WithEnvVariable("GITHUB_API_URL", githubApiUrl)
	}
	return container.
		WithUser("nobody").
		WithExec([]string{"python3", "scripts/update_deploy_health_label.py"}).
		Stdout(ctx)
}

// CreateFirebaseFailureIssue opens (or finds) a GitHub issue describing a
// Firebase Test Lab robo-crawl failure on the Play Store alpha track. Skips
// creation when an open issue with the canonical title already exists, so
// hourly runs cannot pile up duplicates. Replaces the inline Python in
// firebase-tests.yml.
func (m *Ci) CreateFirebaseFailureIssue(
	ctx context.Context,
	githubToken *dagger.Secret,
	runUrl string,
	// +optional
	githubRepository string,
	// +optional
	githubApiUrl string,
) (string, error) {
	scriptSource := m.Source.Filter(dagger.DirectoryFilterOpts{
		Include: []string{"scripts/create_firebase_failure_issue.py"},
	})

	container := dag.Container().
		From("python:3.12-alpine").
		WithFile("/src/scripts/create_firebase_failure_issue.py", scriptSource.File("scripts/create_firebase_failure_issue.py")).
		WithSecretVariable("GITHUB_TOKEN", githubToken).
		WithEnvVariable("RUN_URL", runUrl).
		WithWorkdir("/src")
	if githubRepository != "" {
		container = container.WithEnvVariable("GITHUB_REPOSITORY", githubRepository)
	}
	if githubApiUrl != "" {
		container = container.WithEnvVariable("GITHUB_API_URL", githubApiUrl)
	}
	return container.
		WithUser("nobody").
		WithExec([]string{"python3", "scripts/create_firebase_failure_issue.py"}).
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

    subgraph gh_ci ["GitHub Actions · ci.yml (push/PR, source paths only)"]
        ciCheck["check"]
    end

    subgraph gh_deploy ["GitHub Actions · deploy.yml (hourly schedule + workflow_dispatch)"]
        detectChanges["check-changes\ndetect android / linux diff"]
        buildLinux["build-linux\n(linux changed)"]
        deployPS["deploy-playstore\n(android changed)"]
        deployApk["deploy-apk\n(android changed)"]
        pubWeb["publish-website\n(any build succeeded)"]

        relLinux["release-linux + check-mise-install\nGitHub Release for mise (auto CalVer)"]
        relGui["gui-test-release\nAT-SPI drive vs Stalwart (non-blocking)"]

        detectChanges --> buildLinux
        detectChanges --> deployPS
        detectChanges --> deployApk
        buildLinux  --> relLinux
        relLinux    --> relGui
        buildLinux  --> pubWeb
        deployPS    --> pubWeb
        deployApk   --> pubWeb
    end

    subgraph gh_firebase ["GitHub Actions · firebase-tests.yml (daily cron + workflow_dispatch)"]
        fbTest["test-android-firebase\n(alpha versionCode changed)"]
    end

    subgraph gh_release ["GitHub Actions · release.yml (workflow_dispatch — manual re-release)"]
        relManual["release-linux + check-mise-install\nversion derived from the commit"]
    end

    check -- "task check-dagger" --> ciCheck
` + "```"
}
