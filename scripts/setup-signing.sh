#!/usr/bin/env bash
# Legt EINMALIG die selbst signierte Code-Signing-Identität „UltraDic Signing“ an
# (10 Jahre, extendedKeyUsage codeSigning), importiert sie in den Anmelde-Schlüsselbund,
# vertraut ihr für Codesigning und legt eine .p12-Sicherung ab.
# WARUM PFLICHT: macOS bindet Mikrofon- und Bedienungshilfen-Freigaben an die Code-Signatur der
# App. Ad-hoc signierte Builds (oder eine wechselnde Identität) bekommen bei jedem Update eine
# neue Signatur, und alle Nutzer müssten Mikrofon und Bedienungshilfen neu erteilen. Mit dieser
# stabilen Identität bleiben die Freigaben über Updates hinweg erhalten.
# Nur Ben startet dieses Skript, im Terminal – es fragt nach einem Passwort für die Sicherung
# und macOS fragt beim Vertrauen nach dem Anmeldepasswort.
set -euo pipefail

NAME="UltraDic Signing"
BACKUP="$HOME/Documents/UltraDic-Signing-BACKUP.p12"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# LibreSSL from macOS writes PKCS#12 files that `security import` reads (OpenSSL 3 needs -legacy).
OPENSSL=/usr/bin/openssl

[[ "$(id -u)" -ne 0 ]] || { echo "Nicht als root ausführen." >&2; exit 1; }

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ Identität „${NAME}“ existiert bereits – nichts zu tun."
  security find-identity -v -p codesigning | grep "\"$NAME\""
  exit 0
fi
if [[ -e "$BACKUP" ]]; then
  cat >&2 <<EOF
✗ Es gibt schon eine Sicherung: $BACKUP
  Nicht überschreiben – damit geht die bisherige Identität verloren.
  Wiederherstellen statt neu anlegen:
    security import "$BACKUP" -k "$KEYCHAIN" -T /usr/bin/codesign
  und danach dem Zertifikat für Codesigning vertrauen (Schlüsselbundverwaltung).
EOF
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

cat > "$WORK/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = UltraDic Signing
O = UltraDic

[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "▸ Zertifikat erzeugen (RSA 2048, 10 Jahre)"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

echo "Die Sicherung wird mit einem eigenen Passwort geschützt. Passwort und .p12-Datei"
echo "gehören danach in den Passwort-Manager."
read -r -s -p "Passwort für die Sicherung: " P12_PASS; echo
read -r -s -p "Passwort wiederholen: " P12_REPEAT; echo
if [[ -z "$P12_PASS" || "$P12_PASS" != "$P12_REPEAT" ]]; then
  echo "✗ Passwörter leer oder verschieden." >&2
  exit 1
fi
export P12_PASS

"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout env:P12_PASS
install -m 600 "$WORK/identity.p12" "$BACKUP"

echo "▸ In den Anmelde-Schlüsselbund importieren (codesign darf den Schlüssel nutzen)"
# `security import` only takes the password via -P (visible in `ps`). So the backup password
# never goes there: import a throwaway copy with a random one-off password instead. It only
# protects a file inside the 0700 work dir that already holds key.pem in plaintext.
unset P12_PASS P12_REPEAT
IMPORT_PASS="$("$OPENSSL" rand -hex 16)"
export IMPORT_PASS
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/import.p12" -passout env:IMPORT_PASS
security import "$WORK/import.p12" -k "$KEYCHAIN" -P "$IMPORT_PASS" -T /usr/bin/codesign -T /usr/bin/security
unset IMPORT_PASS

echo "▸ Für Codesigning vertrauen (macOS fragt nach deinem Anmeldepasswort)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ Identität bereit:"
  security find-identity -v -p codesigning | grep "\"$NAME\""
else
  echo "✗ Identität ist nicht als gültig gelistet – Vertrauenseinstellung in der Schlüsselbundverwaltung prüfen." >&2
  exit 1
fi

cat <<EOF

WICHTIG: Sicherung liegt unter
  $BACKUP
→ Datei und Passwort in den Passwort-Manager legen. Ohne diese Sicherung bekommt UltraDic nach
  einem neuen Mac/Schlüsselbund eine neue Identität, und alle Macs fragen Freigaben neu ab.
Ab jetzt signiert build.sh (und damit scripts/release.sh) automatisch mit „${NAME}“.
EOF
