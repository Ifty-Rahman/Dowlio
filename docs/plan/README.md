# Dowlio build plan

This folder holds the build plan for Dowlio. Build the phases in order. Each phase ends with a version of the app that runs and can ship to GitHub.

Read these two files before any phase:

- [architecture.md](architecture.md) records every technology choice and how the parts talk to each other.
- [design.md](design.md) describes the interface. It follows the Flow design and lists what Dowlio changes.

## Phases

| Phase | File | Result |
|---|---|---|
| 1 | [phase-01-project-and-release-pipeline.md](phase-01-project-and-release-pipeline.md) | An empty Dowlio app that builds, signs and publishes a DMG to GitHub Releases from one command |
| 2 | [phase-02-download-engine.md](phase-02-download-engine.md) | A tested segmented download engine, driven from a command-line tool |
| 3 | [phase-03-app-and-interface.md](phase-03-app-and-interface.md) | The Mac app: library window, New Download sheet, menu bar, settings, onboarding, history |
| 4 | [phase-04-catch-downloads.md](phase-04-catch-downloads.md) | The browser extension and the app's browser link. Downloads clicked in Chrome, Arc, Brave or Edge finish in Dowlio |
| 5 | [phase-05-send-to-dowlio.md](phase-05-send-to-dowlio.md) | Send to Dowlio: a shortcut or button sends the current page, Dowlio finds the files and media on it, and the user picks one |
| 6 | [phase-06-media-downloads.md](phase-06-media-downloads.md) | HLS streams, yt-dlp site support, and merging audio and video |
| 7 | [phase-07-queue-and-recovery.md](phase-07-queue-and-recovery.md) | Queue, schedule, speed limit, duplicate checks, expired-link recovery, disk-full handling |
| 8 | [phase-08-github-release.md](phase-08-github-release.md) | Automatic updates, install guide, diagnostics, and a release checklist for public GitHub builds |
| 9 | [phase-09-app-store-edition.md](phase-09-app-store-edition.md) | The sandboxed Mac App Store edition and the Safari extension |

## How to use a phase file

Each phase file has the same sections:

1. Goal: what the phase delivers.
2. Before you start: which phases must be done.
3. How it's built: the technology and method for this phase.
4. Steps: the work in order.
5. Done when: checks that must pass before the next phase starts.
6. Out of scope: work that belongs to a later phase.

Decisions go in `docs/adr/` as numbered files. A phase file that says `docs/adr/NNNN-name.md` means the next free number at the time it's written.

A phase can be broken into tickets with `/to-spec` and `/to-tickets`. Those land in `.scratch/<feature>/`, as `docs/agents/issue-tracker.md` describes.

## Where the ideas come from

[../research.md](../research.md) holds the evidence from Download Shuttle, Neat Download Manager, Downie, Cobalt and Flow. Phase files cite it as "research §N". It stays on the maintainer's Mac and isn't in the public repository, so the link only works locally.
