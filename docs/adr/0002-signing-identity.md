# 0002: Signing identity for GitHub builds

Status: accepted, 2026-10-23

## Decision

GitHub builds are signed with one self-signed code-signing certificate named "Dowlio Self Signed". `scripts/make-signing-cert.sh` creates it once, with RSA 2048 and a 10-year validity. The same certificate signs every release until Dowlio moves to a Developer ID certificate in phase 9.

Copies of the certificate:

| Copy | Where | Purpose |
|---|---|---|
| GitHub secrets `SIGNING_CERT_P12` and `SIGNING_CERT_PASSWORD` | The Dowlio repository | Release workflow |
| Login keychain | The owner's Mac | Local release builds |
| `dowlio-signing.p12` | iCloud Drive, in a private folder | Backup |
| The `.p12` password | Passwords app, as its own entry | Backup |

The file and its password are stored in different places. The login keychain copy isn't a backup, because iCloud Keychain doesn't sync certificates or private keys from the login keychain.

## Why

- Without an Apple Developer account, the options are ad-hoc signing or a self-signed certificate.
- macOS ties a non-Apple signature's designated requirement to the certificate itself. Automation grants, Keychain item access and the browser pairing token all depend on it.
- An ad-hoc signature changes with every build, so every update would reset those permissions. A fixed self-signed certificate keeps them across updates.

## Consequences

- Losing every copy, or creating a new certificate, changes the app's identity. Users then have to grant Automation again, and Keychain items, including browser pairings, become unreadable.
- The release workflow refuses to publish when the secrets are missing, so an ad-hoc build can't reach users by accident.
- The certificate expires in 2036. Phase 9 replaces it with Developer ID long before then. That change also resets permissions once, and the phase 9 release notes must say so.
- Users still see the Gatekeeper warning on first launch, because the app isn't notarized.
