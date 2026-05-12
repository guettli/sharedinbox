# Technical Audit for Play Store Readiness

Your generated `.aab` (App Bundle) is technically valid, but to be fully "Play Store ready," you should verify these four areas:

## 1. Target SDK Version
Google requires apps to target at least **Android 14 (API level 34)**.
Current status: **PASS** (Flutter defaults to 34+ in recent versions).

## 2. Versioning
*   **`versionName`**: Currently `0.1.1`. This is visible to users.
*   **`versionCode`**: This must be a **unique integer** for every single upload to the Play Console.
    *   If you need to re-upload the same version because of a fix, you must increment the code (e.g., from `1` to `2`).
    *   Set this in `pubspec.yaml`: `version: 0.1.1+1` (the number after the `+` is the `versionCode`).

## 3. App Icon
Check your icons in `android/app/src/main/res/mipmap-*`.
*   **Status:** Currently using default `ic_launcher.png`.
*   **Requirement:** Replace these with your own branding before submission. Google may reject apps that use default placeholder logos for being "Low Quality."

## 4. Privacy & Data Safety (Crucial)
Google requires these before you can move to production:
*   **Privacy Policy:** You **must** provide a public URL to a privacy policy.
*   **Data Safety Section:** You must complete the questionnaire in the Play Console.
    *   Since this is an **Email app**, you must declare that it handles "Personal Communications" and potentially "User IDs" or "Contact Info."

## 5. Helpful Commands
To inspect your bundle's manifest (to verify permissions or package name):
```bash
# requires bundletool
bundletool dump manifest --bundle build/app/outputs/bundle/release/app-release.aab
```

**Next Step Recommendation:** Complete the Privacy Policy and Data Safety questionnaire in the Play Console as they often take the longest to be approved.
