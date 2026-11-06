#!/usr/bin/env bash
# make_signing_key.sh - create the signing key for the Termux E-Paper release set (PKCS12, RSA 4096).
#
#   bash .github/scripts/make_signing_key.sh [target-dir]        (default: ~/epaper-signing-key)
#
# Run it on a device you trust. Nothing secret is printed: the files stay in the target directory (mode 600).
#   release.p12      the keystore
#   password.txt     its password (also used for the key)
#   release.p12.b64  the keystore as one line of base64, ready for the repository secret
#   cert.pem         the public certificate
#
# BACK THESE FILES UP OFFLINE (not only in the repository secrets). Whoever has them can sign updates that
# every installed copy accepts, and if they are lost every user has to uninstall and reinstall everything.
#
# The workflow .github/workflows/release_set.yml reads four repository secrets (Settings > Secrets and
# variables > Actions) when it runs with signing=release-key:
#   SIGNING_KEYSTORE_BASE64    content of release.p12.b64
#   SIGNING_KEYSTORE_PASSWORD  content of password.txt
#   SIGNING_KEY_PASSWORD       content of password.txt (the same)
#   SIGNING_KEY_ALIAS          epaper-release (or $KEY_ALIAS)
set -euo pipefail

OUT="${1:-$HOME/epaper-signing-key}"
ALIAS="${KEY_ALIAS:-epaper-release}"
command -v openssl >/dev/null 2>&1 || { echo "openssl is needed" >&2; exit 1; }
umask 077
mkdir -p "$OUT"
if [ -e "$OUT/release.p12" ]; then
    echo "$OUT/release.p12 already exists: not overwriting a signing key." >&2
    exit 1
fi

pass="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 10950 \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -subj "/CN=Termux E-Paper/O=epaper-dev" 2>/dev/null
openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -name "$ALIAS" \
    -out "$OUT/release.p12" -passout "pass:$pass"
rm -f "$OUT/key.pem"
printf '%s' "$pass" > "$OUT/password.txt"
base64 -w0 < "$OUT/release.p12" > "$OUT/release.p12.b64"

echo "Created in $OUT:"
ls -l "$OUT" | sed 's/^/  /'
echo
echo "Certificate (SHA-256), this is what every APK of the set will carry:"
openssl x509 -in "$OUT/cert.pem" -noout -fingerprint -sha256 | sed 's/^/  /'
echo
echo "Next: back up the files offline, then add the four secrets (see the header of this script)."
