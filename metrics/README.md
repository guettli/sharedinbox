# App-size history

## `android-app-size.tsv`

One row per **published** Android build (the Play Store alpha deploy appends it;
see the `Record app size` step in `.github/workflows/deploy.yml`). The point is
that the *next* size change points at its own cause instead of needing an
archaeological dig — which is exactly what issue-triggered this: the Play
download size jumped once with no record of what it used to be.

Tab-separated, one header line. Columns:

| column | meaning |
|---|---|
| `date_utc` | build time, `YYYY-MM-DD HH:MM` UTC |
| `git_hash` | short commit the build was cut from (maps a row to the code) |
| `version_name` | `pubspec.yaml` version, e.g. `0.1.1` |
| `version_code` | Play Store versionCode (Unix time at publish); `unknown` if unavailable to the recorder |
| `flutter` | Flutter SDK from `.fvmrc` (the engine → `libflutter.so`) |
| `install_mb` | **headline**: `install_arm64_bytes` in MB — the number to eyeball |
| `install_arm64_bytes` | uncompressed bytes delivered to an arm64-v8a device: base manifest + dex + arm64 libs + assets + res. Tracks the user-visible download/install size. |
| `libapp_bytes` | `libapp.so` — your Dart code, AOT-compiled (usually the biggest *variable* item) |
| `libflutter_bytes` | `libflutter.so` — the Flutter engine (changes with the Flutter version) |
| `native_other_bytes` | other native libs: SQLCipher/OpenSSL, BoringSSL, … |
| `dex_bytes` | `classes*.dex` — Kotlin/Java (plugins) |
| `assets_bytes` | `base/assets` (incl. `flutter_assets`, fonts) |
| `res_bytes` | `base/res` + `resources.pb` |
| `aab_file_bytes` | the raw `.aab` **upload** size |
| `debug_symbols_bytes` | native debug symbols in the AAB (`debugSymbolLevel=FULL`). **Play strips these before download** — they inflate `aab_file_bytes` but are *not* delivered. Here only so the upload size is never mistaken for the install size. |

Only the device's own ABI ships from an AAB, so `install_arm64_bytes` is the
arm64 figure; other ABIs and `BUNDLE-METADATA/` are deliberately excluded.

## Regenerate / inspect a row by hand

```bash
task android-size-report      # builds the AAB (cached) and prints the breakdown
# or, against an existing bundle:
python3 scripts/android_size_report.py build/app/outputs/bundle/release/app-release.aab \
    --git-hash "$(git rev-parse --short HEAD)" --version-name 0.1.1 --flutter 3.47.7
```

## Context: the ~14 MB → ~38 MB history before this file existed

The 14 MB baseline was the May 2026 build (first Play deploy, `65aba81`),
*before* encryption-at-rest. Between then and now the app added SQLCipher/OpenSSL
(`#610`, June; reworked in `#521`, Aug), a Flutter engine bump (3.41 → 3.47), and
grew its Dart code ~5× — so the delivered size rose with real functionality.
From this file onward the split is visible per build.
