# Phase 1: Project and release pipeline

## Goal

An empty Dowlio app that builds, runs, signs and publishes to GitHub Releases. Doing this first means every later phase can ship a test build the same day.

## Before you start

Nothing. Install Xcode, XcodeGen (`brew install xcodegen`) and the GitHub CLI.

## How it's built

- XcodeGen reads `project.yml` and generates `Dowlio.xcodeproj`. The generated project isn't committed. Agents and people edit `project.yml`, never the `.pbxproj`.
- The app target is a SwiftUI app with an `NSApplicationDelegateAdaptor`. Minimum macOS 14. Bundle ID `io.github.ifty-rahman.Dowlio`, fixed by `docs/adr/0001-bundle-identifier.md`.
- `Packages/DowlioKit` is a local Swift package. The app depends on it. It starts with one module, `DowlioCore`, and an empty test.
- Shell scripts in `scripts/` do every build step, so CI and a laptop run the same commands.
- Signing uses a self-signed certificate called "Dowlio Self Signed" (architecture.md, signing section).
- GitHub Actions uses the free macOS runner. Keep the repository public so the minutes are free.

## Steps

1. Create `project.yml`, `App/` with a single empty window, `Packages/DowlioKit` and `.gitignore`. The ignore list covers `Dowlio.xcodeproj`, `build/`, `.build/` and `DerivedData/`.
2. Add `scripts/bootstrap.sh`, which runs `xcodegen generate`.
3. Add `scripts/test.sh`, which runs `swift test` in `Packages/DowlioKit`, then builds the app with `xcodebuild`.
4. Create the signing certificate once:
   - Use Keychain Access › Certificate Assistant, with type Code Signing and a 10-year validity.
   - Export it as a `.p12` with a password.
   - Store it as the GitHub secrets `SIGNING_CERT_P12` (base64) and `SIGNING_CERT_PASSWORD`.
   - Keep one offline backup. Losing it resets user permissions on the next update.
5. Add `scripts/build-release.sh`:
   - It runs `xcodebuild archive` for arm64 and x86_64, then exports the app.
   - It signs nested code first, then the app, with `codesign --options runtime --sign "Dowlio Self Signed"`.
   - It verifies with `codesign --verify --deep --strict`.
6. Add `scripts/package.sh`. It makes `Dowlio-<version>.dmg` with `hdiutil`: the app plus an Applications link and a background image. It also makes `Dowlio-<version>.zip` with `ditto -c -k --keepParent`. It writes SHA-256 sums for both files.
7. Add `.github/workflows/ci.yml`, which runs `scripts/test.sh` on every push and pull request.
8. Add `.github/workflows/release.yml`. On a `v*` tag it:
   - imports the certificate into a temporary keychain,
   - runs the build and package scripts,
   - creates a GitHub Release with `gh release create` and uploads the DMG, ZIP and checksums.
9. Set the version in one place, `project.yml`. `MARKETING_VERSION` follows `MAJOR.MINOR.PATCH` and the tag must match it. The release script fails if they differ.
10. Write a first draft of the `README.md` install section. It says the app isn't notarized and explains Open Anyway. Phase 8 adds screenshots.

## Done when

- `scripts/test.sh` passes locally and in CI.
- Pushing tag `v0.0.1` produces a GitHub Release with a DMG and a ZIP.
- On another Mac user account, downloading the DMG, dragging the app to Applications and using Open Anyway opens the empty window.
- `codesign -dvv` on the release shows "Dowlio Self Signed" and the hardened runtime flag.

## Out of scope

Sparkle updates (phase 8), the app icon (phase 3) and any real feature.
