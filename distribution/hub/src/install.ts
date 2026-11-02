// GET /install.sh – first install of UltraDic on a Mac:
//   curl -fsSL https://ugreen-nas.tail076274.ts.net:8452/install.sh | bash
// curl sets no quarantine attribute; the script removes it anyway for safety.

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

/** Script used when latest.zip is missing on the hub: explains and fails. */
export function missingReleaseScript(): string {
  return `#!/bin/bash
# UltraDic – Installation (vom Hub ausgeliefert)
set -euo pipefail
echo "UltraDic-Installation abgebrochen: Auf dem NAS liegt noch keine Version (updates/latest.zip fehlt)." >&2
echo "Bitte zuerst ein Release hochladen und dann erneut starten." >&2
exit 1
`;
}

export function installScript(hubURL: string): string {
  return `#!/bin/bash
# UltraDic – Installation (vom Hub ausgeliefert)
# Lädt die aktuelle Version vom NAS, ersetzt ~/Applications/UltraDic.app und startet sie.
set -euo pipefail

HUB=${shellQuote(hubURL)}
ZIEL_ORDNER="$HOME/Applications"
ZIEL="$ZIEL_ORDNER/UltraDic.app"

fehler() {
  echo "UltraDic-Installation abgebrochen: $*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fehler "Dieses Skript läuft nur auf macOS."
command -v curl >/dev/null || fehler "curl fehlt."
command -v ditto >/dev/null || fehler "ditto fehlt."

ARBEIT="$(mktemp -d "\${TMPDIR:-/tmp}/ultradic-install.XXXXXX")"
trap 'rm -rf "$ARBEIT"' EXIT

echo "Lade UltraDic vom NAS …"
status=0
curl -fsSL -o "$ARBEIT/UltraDic.zip" "$HUB/updates/latest.zip" || status=$?
if [ "$status" -ne 0 ]; then
  if [ "$status" -eq 22 ]; then
    fehler "Auf dem NAS liegt keine UltraDic-Version (updates/latest.zip fehlt oder ist gesperrt)."
  fi
  fehler "Download fehlgeschlagen (curl-Fehler $status). Ist Tailscale verbunden?"
fi

echo "Entpacke …"
ditto -x -k "$ARBEIT/UltraDic.zip" "$ARBEIT/entpackt" || fehler "Archiv ließ sich nicht entpacken."
NEU="$(find "$ARBEIT/entpackt" -maxdepth 2 -type d -name 'UltraDic.app' | head -n 1)"
[ -n "$NEU" ] || fehler "Im Archiv wurde keine UltraDic.app gefunden."

# Quit a running UltraDic so the bundle can be replaced.
if pgrep -f "/UltraDic.app/Contents/MacOS/" >/dev/null 2>&1; then
  echo "Beende laufende UltraDic …"
  osascript -e 'tell application "UltraDic" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -f "/UltraDic.app/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pgrep -f "/UltraDic.app/Contents/MacOS/" >/dev/null 2>&1 && pkill -f "/UltraDic.app/Contents/MacOS/" || true
fi

mkdir -p "$ZIEL_ORDNER"
ALT=""
if [ -e "$ZIEL" ]; then
  ALT="$ARBEIT/UltraDic-vorher.app"
  mv "$ZIEL" "$ALT" || fehler "Die bisherige UltraDic.app ließ sich nicht ersetzen."
fi
if ! ditto "$NEU" "$ZIEL"; then
  rm -rf "$ZIEL"
  [ -n "$ALT" ] && mv "$ALT" "$ZIEL"
  fehler "UltraDic.app ließ sich nicht nach $ZIEL_ORDNER kopieren."
fi
xattr -dr com.apple.quarantine "$ZIEL" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ZIEL/Contents/Info.plist" 2>/dev/null || true)"
open "$ZIEL" || fehler "UltraDic ist installiert, ließ sich aber nicht starten: $ZIEL"
echo "Fertig: UltraDic\${VERSION:+ $VERSION} ist installiert ($ZIEL) und startet jetzt."
echo
echo "Noch zu tun (einmalig):"
echo "  1. Mikrofon-Zugriff erlauben, wenn macOS danach fragt."
echo "  2. Bedienungshilfen erlauben: Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen > UltraDic."
echo "  3. In den UltraDic-Einstellungen deinen eigenen OpenAI-Schlüssel eintragen"
echo "     (für den Mail-Modus zusätzlich deinen Anthropic-Schlüssel) und bei \\"Dein Name\\" deinen Namen."
`;
}
