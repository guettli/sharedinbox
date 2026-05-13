# Play Store Publishing Roadmap

To publish the Flutter app to the Play Store, you need to transition from a "development" state to a "production-ready" state.

Data Protection blabla page!

## 1. What has been done
*   **Application ID:** Changed to `de.sharedinbox.mua` (verified in `build.gradle.kts`, `MainActivity.kt`, and integration tests).
*   **Build Logic:** `android/app/build.gradle.kts` now supports:
    *   **Local builds:** Using `key.properties` (ignored by git).
    *   **CI builds:** Using environment variables (`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEYSTORE_PASSWORD`).
*   **Taskfile:** Added `task build-android-bundle` to generate the `.aab` file.
*   **CI Workflow:** Created `.forgejo/workflows/release.yml` which triggers on merge to `main`.

## 2. What you need to do next
### A. Create the Keystore
Run the helper script I created for you:
```bash
./t.sh
```
Follow the prompts and use a strong password (24-32 chars).

### B. Configure Codeberg Secrets
Go to **Settings > Actions > Secrets** in your Codeberg repo and add:
1.  **`ANDROID_KEYSTORE_BASE64`**: The output of `base64 -w 0 android/app/upload-keystore.jks`.
2.  **`ANDROID_KEYSTORE_PASSWORD`**: Your keystore password.
3.  **`PLAY_STORE_CONFIG_JSON`**: The JSON key from your Google Play Service Account.

### C. First Manual Upload
Google Play requires the **very first upload** to be done manually through the web console:
1.  Generate your keystore using `./t.sh`.
2.  Run the build locally using temporary environment variables:
    ```bash
    export ANDROID_KEYSTORE_PASSWORD=your_password
    nix develop --command task build-android-bundle
    ```
3.  Upload the resulting `.aab` from `build/app/outputs/bundle/release/app-release.aab` to the Play Console (Internal Testing or Production track).
4.  This "locks in" your signing key.

## 3. Firebase Test Lab
Once you have the Service Account JSON, you can add a task to `Taskfile.yml` to run automated tests on real devices:
```yaml
test-lab:
  desc: Run integration tests in Firebase Test Lab
  cmds:
    - gcloud firebase test android run \
      --type instrumentation \
      --app build/app/outputs/apk/debug/app-debug.apk \
      --test build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk \
      --device model=virtuall1,version=30
```

**Recommendation:** Complete step **A** (Keystore) and **B** (Secrets) first. Once the first manual upload is done, the CI will take over for all future merges to `main`.
