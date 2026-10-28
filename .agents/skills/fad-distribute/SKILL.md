---
name: fad-distribute
description: Distribute the r2-gallery Flutter release APK through Firebase App Distribution. Merging to main ships it automatically via the operator-managed r2-flutter-build lane; use this to confirm a release or to force one.
---

# FAD distribution (r2-gallery)

Distribution is automatic: merge to `main` and it ships. Nobody needs to dispatch anything.

## How it works

The signing key and the baked worker token live only in a separate operator-managed build
repository, so this repo does not build the APK itself. Its `r2-flutter-build` workflow polls
instead, like `r2-web-deploy` does for the web build:

1. Every 15 minutes it reads the `main` SHA and compares it with `.source-sha` on the
   `fad-dist-state` branch of this repo (the last SHA it distributed).
2. When they differ it builds the Flutter release APK (`app-release.apk`, `applicationId app.r2gallery`) with
   `--dart-define=R2_BAKED_ENDPOINT/R2_BAKED_TOKEN` from that repository's secrets, so the app connects on
   first launch without asking for a token.
3. The versionCode is `pubspec build number + run_number`, so every release installs as an update.
4. It uploads to Firebase App Distribution (project `r2-gallery-c0ca`, app
   `1:380147062326:android:5a77ec11925136089c2a97`, tester = the owner only, see `ALLOWED_TESTERS` in `tools/app-distribute.sh`) and writes the
   distributed SHA to `fad-dist-state`.

The release build is signed with the pinned debug key from `secrets.DEBUG_KEYSTORE_BASE64`
(`android/app/build.gradle.kts` points `release` at the debug signing config). Keep that key so
tester installs keep updating. Do not switch back to `--debug`: a Flutter debug APK runs JIT and is
several times slower than the KMP client was.

The APK is never uploaded as an artifact: the build repository is public and the APK carries the baked token.

## Confirm a release

- Find the latest run:
  list the `r2-flutter-build.yml` runs with `event=schedule` in the operator-managed build repository.
  `conclusion=success` means it was distributed. The log prints the FAD release.
- Read `.source-sha` on `fad-dist-state`. It should equal the merged `main` SHA.

## Force a release

Dispatch `r2-flutter-build` with `ref=main` and `distribute=true`. Any other ref only builds and
tests. It never distributes, so branch builds cannot reach testers.
