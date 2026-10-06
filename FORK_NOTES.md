# Spotube "Listen Along" fork — notes

This is a fork of **Spotube v5.1.2** (`team-spotube/spotube`) that makes the
Friend Activity plugin work properly on-device. It is the host half of the
`spotify-plugin-listen-along` plugin (see `../spotify-plugin-listen-along`).

## Why a host fork

The plugin (a Hetu metadata provider) can already show friends' current tracks
and play them. Three things could only be fixed in the host:

1. **Startup 401 spam** — several Browse/library providers called the plugin
   before the plugin had restored its access token, sending `Bearer null`.
2. **Stale Friend Activity** — Browse sections were fetched once per session and
   never refreshed.
3. **Login webview crash** — `onNavigatorPop` popped a detached context.

## Changes in this fork

| File | Change |
|---|---|
| `lib/provider/metadata_plugin/album/releases.dart` | `build()` now `await`s `metadataPluginAuthenticatedProvider.future` and returns an empty page when unauthenticated (fixes `Bearer null` 401 on the "What's New" feed). |
| `lib/provider/metadata_plugin/browse/sections.dart` | Same await-auth guard, plus a 30s `Timer.periodic` that calls `ref.invalidateSelf()` so sections (Friend Activity) refresh live while authenticated. |
| `lib/services/metadata/metadata.dart` | `onNavigatorPop` guards `pageContext` and `context.mounted` before `maybePop()` (fixes the login webview close crash). |

All three are small, additive, and safe to upstream as-is.

## Build (cloud — recommended)

Local builds need the Flutter SDK (~12 GB); this machine only has ~5 GB free, so
use the included GitHub Actions workflow:

1. Create an empty repo, e.g. `https://github.com/<you>/spotube-listen-along`.
2. Publish this fork and trigger the build:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/publish-fork.ps1 `
       -RepoUrl https://github.com/<you>/spotube-listen-along.git
   ```

3. On GitHub: **Actions → "Build Spotube (Listen Along fork) Android APK" → Run
   workflow**.
4. Download the **`spotube-android-apk`** artifact (`Spotube-android-all-arch.apk`).

The workflow (`.github/workflows/android-build.yml`) uses Flutter 3.35.2, Java
17, Rust, generates a throwaway debug keystore, and runs
`dart cli/cli.dart build --arch=all android`.

## Build (local, if you free up disk)

Requires Flutter **3.35.2**, JDK 17, Rust, Android SDK.

```bash
flutter pub get
dart cli/cli.dart install-dependencies --platform=android --arch=all
# create android/key.properties + android/app/upload-keystore.jks (or reuse the
# CI debug keystore recipe)
CHANNEL=stable DOTENV="ENABLE_UPDATE_CHECK=0" dart cli/cli.dart build --arch=all android
# -> build/Spotube-android-all-arch.apk
```

## Install & verify

1. Install the APK (it is a debug-signed build; allow "install unknown apps").
2. Install the plugin `spotify-plugin-listen-along/build/plugin.smplug`
   (Settings → Metadata provider plugins), set it as **default metadata source**,
   and **Login**.
3. Set a **default audio source plugin** (e.g. YouTube Music).
4. Open **Browse → Friend Activity**. It should populate after login and refresh
   every 30s without the earlier 401 spam.

## Upstreaming

Once verified on-device, the three host changes above can be split into two
small PRs:

- **PR A:** await-auth guards in `releases.dart` + `sections.dart` (bugfix).
- **PR B:** periodic section refresh in `sections.dart` (feature).

See `../spotify-plugin-listen-along/docs/PHASE2_PR_PLAN.md` for the optional
playback-control API that would enable true continuous "Listen Along".
