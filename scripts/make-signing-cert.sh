#!/usr/bin/env bash
# Creates the "Dowlio Self Signed" code-signing certificate once.
#
# It writes dist-secrets/dowlio-signing.p12 and prints the commands that store it as GitHub
# secrets. It touches no keychain unless you pass --import-to-login-keychain.
#
# Keep a private backup of the .p12. A new certificate changes the app's identity, and macOS then
# resets the permissions users granted (Automation, Keychain items).
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT="$ROOT/dist-secrets"
IMPORT=0
[ "${1:-}" = "--import-to-login-keychain" ] && IMPORT=1

[ -e "$OUT/dowlio-signing.p12" ] && die "$OUT/dowlio-signing.p12 already exists. Delete it first if you really want a new identity."
mkdir -p "$OUT"
chmod 700 "$OUT"
cd "$OUT"

PASSWORD="$(openssl rand -base64 24)"

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_IDENTITY_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$SIGN_IDENTITY_NAME" \
  -out dowlio-signing.p12 -passout "pass:$PASSWORD"
rm -f key.pem cert.pem cert.cnf
chmod 600 dowlio-signing.p12

if [ "$IMPORT" = 1 ]; then
  log "Importing into the login keychain"
  security import dowlio-signing.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASSWORD" -T /usr/bin/codesign
fi

cat <<MSG

Created $OUT/dowlio-signing.p12 (valid 10 years).
Password: $PASSWORD

1. Store both as GitHub secrets:

  base64 -i $OUT/dowlio-signing.p12 | gh secret set SIGNING_CERT_P12
  printf '%s' '$PASSWORD' | gh secret set SIGNING_CERT_PASSWORD

2. Back up, as docs/adr/0002-signing-identity.md describes:
   - copy dowlio-signing.p12 to a private folder in iCloud Drive,
   - save the password in the Passwords app as its own entry.

3. Then delete $OUT. The login keychain keeps a working copy if you imported it.
MSG
