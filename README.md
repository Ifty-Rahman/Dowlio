# Dowlio

A fast, private, native download manager for macOS. Dowlio takes downloads from your browser, splits large files across several connections, and downloads media from pages that have no download button.

Dowlio is under development. The build plan is in [docs/plan](docs/plan/README.md).

## Install

Download `Dowlio-<version>.dmg` from the [latest release](../../releases/latest). Dowlio needs macOS 14 or later.

Dowlio isn't notarized yet, because notarization needs a paid Apple Developer account. macOS blocks the first launch. You approve it once:

1. Open the DMG and drag Dowlio to Applications.
2. Open Dowlio. macOS says it can't verify the app. Click Done.
3. Open System Settings, then Privacy & Security.
4. Scroll to the message about Dowlio and click Open Anyway. Confirm with your password.

Dowlio opens normally after that, and updates won't ask again.

From Terminal, this does the same as steps 2 to 4:

```
xattr -dr com.apple.quarantine /Applications/Dowlio.app
```

## Build from source

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
brew install xcodegen
./scripts/test.sh            # tests and a Debug build
./scripts/build-release.sh   # signed Release build in build/Release
./scripts/package.sh         # DMG and ZIP in dist/
```

`project.yml` defines the Xcode project. Don't edit `Dowlio.xcodeproj`, because `scripts/bootstrap.sh` regenerates it.

## Release

1. Run `scripts/make-signing-cert.sh` once, store the two secrets it prints, and keep a private backup of the `.p12`.
2. Set `MARKETING_VERSION` in `project.yml`.
3. Push a tag that matches it, for example `git tag v0.1.0 && git push origin v0.1.0`.

GitHub Actions builds, signs and publishes the release. A tag that doesn't match `MARKETING_VERSION` fails the build.

## License

Copyright © 2026 Ifty Rahman. All rights reserved. The source is public to read, but no license to reuse it is granted yet.
