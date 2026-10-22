# Phase 8: GitHub release

## Goal

Dowlio 1.0 on GitHub. Users install it from a DMG, get updates automatically, and can report problems with useful diagnostics. Everything stays free: no Apple Developer account, no paid service.

## Before you start

Phase 7.

## How it's built

### Updates with Sparkle

- Add Sparkle 2 as a Swift package. Create an EdDSA key pair once with Sparkle's `generate_keys`. Put the public key in `Info.plist` as `SUPublicEDKey`. Store the private key as the GitHub secret `SPARKLE_ED_PRIVATE_KEY`.
- The feed URL is `https://github.com/<owner>/Dowlio/releases/latest/download/appcast.xml`. GitHub redirects it to the newest release's asset, so the feed needs no separate hosting.
- The release workflow signs the ZIP with `sign_update`, generates `appcast.xml` with the version, release notes and signature, and uploads it with the release.
- Sparkle checks once a day by default, and Settings › General gets "Check for updates automatically" and Check Now.
- The self-signed certificate stays the same, so Sparkle's signature check and macOS permissions keep working across updates.
- Test the update path from a self-signed, non-notarized build before 1.0. Record any Sparkle warnings about unsigned apps in `docs/adr/NNNN-updates.md`.

### Install guide

- `README.md` and the GitHub Release notes show four steps with screenshots: open the DMG, drag to Applications, open once and see the warning, then System Settings › Privacy & Security › Open Anyway.
- A short note explains why: Dowlio isn't notarized because that needs a paid Apple Developer account, and the App Store edition comes later.
- An advanced note gives the Terminal alternative, `xattr -dr com.apple.quarantine /Applications/Dowlio.app`.

### Diagnostics

- Settings › General › Diagnostics shows the app version, macOS version, browser link state per browser, yt-dlp version and hash status, the ffmpeg helper version, and the last 200 log lines with URLs and paths removed.
- Copy Diagnostics puts that text on the clipboard. Report a Problem opens a GitHub issue with the text in its body. Nothing is sent anywhere automatically.

### Privacy and legal files

- `PRIVACY.md`: what Dowlio stores, where, for how long, and which servers it contacts. It has no analytics or tracking.
- `THIRD_PARTY_NOTICES.md`: Sparkle, GRDB, KeyboardShortcuts, FFmpeg (LGPL, with a source link) and yt-dlp (Unlicense, downloaded at runtime, not bundled).
- `LICENSE` for Dowlio itself. The choice of licence is yours.
- A "Responsible use" section in `README.md`: Dowlio doesn't bypass DRM, paywalls or login requirements, and users must follow the terms of the sites they use.

### Release checklist

Run it for every release, on a second macOS user account:

1. Fresh install from the DMG with Open Anyway.
2. Onboarding end to end, including Add for one browser and the shortcut prompt.
3. Catch a file in Arc and in Chrome.
4. Send a page with an MP4, an HLS stream and a yt-dlp site.
5. Pause, quit, reopen, resume.
6. Update from the previous release through Sparkle. Permissions and pairing must survive.

## Steps

1. Add Sparkle, the keys, and the appcast steps in the release workflow.
2. Test an update from `v0.5.0` to a `v0.5.1` test build on a clean account.
3. Build the Diagnostics view and Report a Problem.
4. Write the install guide, `PRIVACY.md`, `THIRD_PARTY_NOTICES.md` and the responsible-use section.
5. Review every user-visible string for plain wording and consistent terms.
6. Run the release checklist.
7. Release `v1.0.0`.

## Done when

- A user on a clean Mac installs, onboards, catches a download and sends a page by following only the README.
- `v1.0.0` updates itself to a later test build with no new permission prompts and without breaking the browser link.
- Diagnostics text contains no URLs, file names or user paths.

## Out of scope

The App Store edition (phase 9).
