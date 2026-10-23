# App-size history

## Where the data lives

main is protected (a pull request is required — nothing pushes to it directly),
so the size history can't live here and be appended by CI. It accumulates on a
dedicated, unprotected orphan branch, **`app-size-history`**, as a single file:

> https://github.com/guettli/sharedinbox/blob/app-size-history/android-app-size.tsv

One row is appended per **published** Android build by the non-blocking
`Record app size` step in `.github/workflows/deploy.yml` (→
`scripts/record_android_size.sh`). The point: the *next* size change points at
its own cause instead of needing an archaeological dig — which is what triggered
this (the Play download size jumped once and we had no record of what it was).

## Columns (tab-separated, one header line)

| column | meaning |
|---|---|
| `date_utc` | build time, `YYYY-MM-DD HH:MM` UTC |
| `git_hash` | short commit the build was cut from (the primary key — maps a row to the code) |
| `version_name` | `pubspec.yaml` version, e.g. `0.1.1` |
| `version_code` | Play versionCode if available, else `unknown` (the recorder measures the pre-stamp cached bundle) |
| `flutter` | Flutter SDK from `.fvmrc` (drives `libflutter.so`) |
| `install_mb` | **headline**: `install_arm64_bytes` in MB — the number to eyeball |
| `install_arm64_bytes` | uncompressed bytes an arm64-v8a device receives: base manifest + dex + arm64 libs + assets + res |
| `libapp_bytes` | `libapp.so` — your Dart code, AOT-compiled (usually the biggest *variable* item) |
| `libflutter_bytes` | `libflutter.so` — the Flutter engine (changes with the Flutter version) |
| `native_other_bytes` | other native libs: SQLCipher/OpenSSL, BoringSSL, … |
| `dex_bytes` | `classes*.dex` — Kotlin/Java (plugins) |
| `assets_bytes` | `base/assets` (incl. `flutter_assets`, fonts) |
| `res_bytes` | `base/res` + `resources.pb` |
| `aab_file_bytes` | the raw `.aab` **upload** size |
| `debug_symbols_bytes` | native debug symbols in the AAB (`debugSymbolLevel=FULL`). **Play strips these before download** — they inflate `aab_file_bytes` but are *not* delivered. Here only so the upload size is never mistaken for the install size. |

**`install_mb` is an on-device install-size proxy, not the Play download
number.** It TRENDS with what the user downloads but reads larger: Play serves
the entries compressed and drops unused densities/languages. Matching Play
exactly is a non-goal — a consistent, diffable trend is. Only the device's own
ABI ships from an AAB, so this is the arm64 figure; other ABIs and
`BUNDLE-METADATA/` are deliberately excluded.

## Inspect / regenerate a row by hand

```bash
task android-size-report      # builds the AAB (cached) and prints the breakdown
# or, against an existing bundle:
python3 scripts/android_size_report.py build/app/outputs/bundle/release/app-release.aab \
    --git-hash "$(git rev-parse --short HEAD)" --version-name 0.1.1 --flutter 3.47.7
```

## Context: the ~14 MB → ~38 MB history from before this file existed

The 14 MB baseline was the May 2026 build (first Play deploy, `65aba81`),
*before* encryption-at-rest. Between then and now the app added SQLCipher/OpenSSL
(`#610`, June; reworked in `#521`, Aug), a Flutter engine bump (3.41 → 3.47), and
grew its Dart code ~5×. From the `app-size-history` branch onward the split is
visible per build.
