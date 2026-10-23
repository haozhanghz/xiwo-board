#!/bin/bash
# Run once, on your own Mac, to create the certificate that release builds are
# signed with (docs/SIGNING.md). It copies the certificate, a base64 PKCS#12
# file, to the clipboard for the repository secret XIWOBOARD_SIGNING_P12 and
# opens the page to add it; nothing is left on disk. Given a file name, it
# writes the base64 there instead.
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = XiwoBoard Release Signing
O = haozhanghz/xiwo-board
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
# The system LibreSSL writes PKCS#12 that `security import` reads; Homebrew's
# OpenSSL 3 does not by default. The password only satisfies the importer
# (scripts/import-signing-identity.sh uses the same one): the file is the secret.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout key.pem -out cert.pem \
    -days 9131 -sha256 -config cert.cnf 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "XiwoBoard Release Signing" \
    -passout pass:xiwoboard -out cert.p12

if [ $# -ge 1 ]; then
    base64 -i cert.p12 | tr -d '\n' > "$1"
    echo "Wrote $1" >&2
else
    base64 -i cert.p12 | tr -d '\n' | pbcopy
    echo "证书已复制到剪贴板。在打开的网页里：Name 填 XIWOBOARD_SIGNING_P12，Secret 里粘贴，再点 Add secret。" >&2
    open "https://github.com/haozhanghz/xiwo-board/settings/secrets/actions/new"
fi
