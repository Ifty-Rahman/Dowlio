# 0001: Bundle identifier

Status: accepted, 2026-10-23

## Decision

Dowlio's bundle identifier is `io.github.ifty-rahman.Dowlio`. Every edition uses it, including the later App Store build.

## Why

- A bundle ID should be reverse-DNS of a domain the developer controls. `ifty-rahman.github.io` is a GitHub Pages domain the owner already controls at no cost. Dowlio doesn't own `dowlio.app`, which the earlier placeholder `app.dowlio.Dowlio` implied.
- macOS keys user state to the bundle ID: preferences, Application Support, Keychain items, Automation and other privacy grants, and login items. Changing it after a release would reset all of that for every user and break browser pairings.

## Consequences

- The ID can't change after `v0.0.1` ships. A new domain later doesn't change it.
- `AppIdentity.bundleIdentifier` in `DowlioCore` and `project.yml` must match. A unit test checks the Swift constant.
