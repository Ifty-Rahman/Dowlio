# Phase 9: App Store edition

## Goal

A sandboxed Dowlio on the Mac App Store, plus a notarized Developer ID build for GitHub, a Safari extension, and Chrome Web Store and Edge Add-ons listings. This phase needs an Apple Developer Program membership.

## Before you start

Phase 8, and an Apple Developer account.

## How it's built

### Two editions from one codebase

- `project.yml` defines two app targets that share every module: `Dowlio` for GitHub, signed with Developer ID and notarized from here on, and `Dowlio App Store`, sandboxed and without Sparkle. App Store builds update through the store.
- `#if APP_STORE` hides Sparkle, Check for Updates and the yt-dlp installer in the store edition.

### What the sandbox changes

| Feature | GitHub edition | App Store edition |
|---|---|---|
| Download folder | Any folder | Downloads folder entitlement, plus folders the user picks, kept as security-scoped bookmarks |
| Browser link | WebSocket on loopback | The same. The sandbox allows a loopback server with `com.apple.security.network.server` |
| Extension install | Unpacked folder | Chrome Web Store and Edge Add-ons listings. Safari through an app extension |
| Front browser URL | Apple Events | Apple Events with `com.apple.security.temporary-exception.apple-events` for each browser bundle ID. Review may reject this, so the extension path is the fallback |
| yt-dlp | Downloaded from GitHub at runtime | App Review rule 2.5.2 bars downloading code that changes the app's features. The store edition probably can't use yt-dlp, so its media support is HLS and direct files only |
| ffmpeg helper | In `Contents/Helpers` | Sandboxed helper with the inherited sandbox entitlement |

Download Shuttle, a store app, blocks YouTube, SoundCloud, Vimeo and Vevo (research §3.4). Expect the same review pressure. Decide the store edition's media scope before submitting.

### Safari extension

- A Safari Web Extension target, converted from the Chrome extension with `xcrun safari-web-extension-converter`.
- A Safari web extension sends native messages only to its containing app, with `browser.runtime.sendNativeMessage`. The app extension's `SafariWebExtensionHandler` receives them and passes them to Dowlio through an app group. The WebSocket link stays for Chromium browsers.
- Catching uses `browser.downloads` where Safari supports it. Where it doesn't, the Safari extension offers Send to Dowlio and "Download link with Dowlio" only. Check the current Safari version's support during this phase.

### Store listings

- Chrome Web Store, with a one-time registration fee. The listing must follow the Chrome Web Store policy quoted in research §4.3. Keep the store extension free of site-specific code. It only catches downloads and sends pages to the app.
- Edge Add-ons, free.
- With store listings, the extension ID is fixed. Pairing still uses the token, so nothing depends on the ID.

## Steps

1. Enroll in the Apple Developer Program. Switch the GitHub edition to Developer ID signing and notarization with `notarytool`. Staple the ticket in the release workflow.
2. Add the App Store target and its entitlements. Fix every sandbox failure.
3. Decide the store edition's media scope and write `docs/adr/NNNN-app-store-scope.md`.
4. Build the Safari extension target and its link to the app.
5. Submit the extension to the Chrome Web Store and Edge Add-ons.
6. Submit the App Store build with clear review notes: what the browser extension does, why the loopback server exists, and that Dowlio refuses DRM.

## Done when

- The GitHub edition opens without Open Anyway, because it's notarized.
- The App Store edition passes review and catches downloads from Chrome through the store-listed extension.
- Safari can send a page to the App Store edition.

## Out of scope

iOS and iPadOS versions.
