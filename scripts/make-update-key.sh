#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
OUT="$ROOT/dist-secrets"
KEY="$OUT/sparkle-ed-private-key"

[ -e "$KEY" ] && die "$KEY already exists. Delete it first if you really want a new key."
mkdir -p "$OUT"
chmod 700 "$OUT"

SCRIPT="$(mktemp -t dowlio-update-key).swift"
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
KEYS="$(swift "$SCRIPT")"

(umask 077 && printf '%s\n' "$(sed -n 1p <<<"$KEYS")" > "$KEY")
log "Wrote $KEY"
log "Public key for SUPublicEDKey in project.yml:"
sed -n 2p <<<"$KEYS"
log "Store the private key as a GitHub secret with:"
echo "  gh secret set SPARKLE_ED_PRIVATE_KEY < \"$KEY\""
