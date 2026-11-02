#!/usr/bin/env bash
# Veröffentlicht eine neue UltraDic-Version über den Hub (Sparkle 2).
#   scripts/release.sh [--first] <version> "<Release-Notes>"
# Ablauf: vorhandenen Appcast vom Hub holen (nicht lesbar → Abbruch, bevor etwas geladen oder
# geändert wird; nur mit --first, für den ersten Release, beginnt ein neuer Appcast)
# → Build-Nummer = größer als project.yml und als jede Build-Nummer im Appcast →
# project.yml vorläufig hochzählen →
# Release-Build (build.sh, universal) → Code-Signatur prüfen → ZIP (ditto) → sign_update (EdDSA) →
# erst jetzt bleibt project.yml hochgezählt (bei jedem Fehler davor wird sie zurückgesetzt)
# → appcast.xml ergänzen → latest.zip → Upload per scp -O → per curl prüfen.
# Danach die geänderte project.yml committen.
#
# EINMALIG VORHER (Ben, im Terminal):
#   1. scripts/setup-signing.sh   – stabile Signatur-Identität „UltraDic Signing“. Pflicht:
#      Mikrofon-/Bedienungshilfen-Freigaben hängen an der Signatur und gehen sonst bei jedem
#      Update verloren.
#   2. Sparkle-Schlüssel (der private Teil bleibt im Anmelde-Schlüsselbund, wird nie exportiert):
#        ~/Library/Caches/ultradic-sparkle/Sparkle-<Version>/bin/generate_keys --account ultradic
#      (Das Werkzeug lädt dieses Skript beim ersten Lauf; alternativ den Ordner aus dem Sparkle-
#      Release-Tarball nehmen.) Ausgegebenen ÖFFENTLICHEN Schlüssel als SPARKLE_PUBLIC_KEY in
#      BlitztextMac/project.yml eintragen und committen.
#   3. Hub-Port prüfen: ULTRADIC_HUB_URL in BlitztextMac/project.yml (einzige Stelle).
#
# Die Funktionen oben lassen sich einzeln prüfen: `source scripts/release.sh` definiert nur
# sie und führt nichts aus (scripts/test-release.sh).

# --- Konfiguration ------------------------------------------------------------------------------
_RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_PROJECT_YML="$_RELEASE_ROOT/BlitztextMac/project.yml"
# Hub base URL: single source is ULTRADIC_HUB_URL in project.yml (also feeds Info.plist SUFeedURL).
HUB_URL="${ULTRADIC_HUB_URL:-$(sed -n 's/^    ULTRADIC_HUB_URL: "\(.*\)"$/\1/p' "$_PROJECT_YML" 2>/dev/null | head -1)}"
UPLOAD_TARGET="${ULTRADIC_UPLOAD_TARGET:-claudedude@ugreen-nas.tail076274.ts.net:/volume1/docker/ultradic-hub/data/updates/}"
IDENTITY_NAME="UltraDic Signing"
SPARKLE_ACCOUNT="ultradic"

# --- Funktionen -------------------------------------------------------------------------------

# Höchste Build-Nummer (sparkle:version, als Element oder Attribut) in einem Appcast, sonst 0.
max_appcast_build() {
  local file="$1" numbers
  [[ -f "$file" ]] || { echo 0; return 0; }
  numbers="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>|sparkle:version="[0-9]+"' "$file" \
    | grep -oE '[0-9]+' || true)"
  if [[ -z "$numbers" ]]; then
    echo 0
  else
    printf '%s\n' "$numbers" | sort -n | tail -1
  fi
}

# Nächste Build-Nummer: eins über dem Größeren aus project.yml und Appcast.
next_build_number() {
  local current="$1" appcast_max="$2"
  if (( appcast_max > current )); then
    echo $((appcast_max + 1))
  else
    echo $((current + 1))
  fi
}

read_project_build() {
  sed -n 's/^    CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' "$1" | head -1
}

set_project_version() {
  local file="$1" version="$2" build="$3"
  sed -i '' \
    -e "s/^    MARKETING_VERSION: \".*\"$/    MARKETING_VERSION: \"$version\"/" \
    -e "s/^    CURRENT_PROJECT_VERSION: \".*\"$/    CURRENT_PROJECT_VERSION: \"$build\"/" \
    "$file"
}

# project.yml vorläufig hochzählen: Bis keep_project_bump läuft, setzt jedes Skriptende
# (Fehler, set -e, Abbruch mit ctrl-c) die Datei auf den alten Stand zurück.
PROJECT_FILE=""
PROJECT_BACKUP=""
begin_project_bump() {
  PROJECT_FILE="$1"
  PROJECT_BACKUP="$(mktemp -t ultradic-project-yml)"
  cp "$PROJECT_FILE" "$PROJECT_BACKUP"
  trap restore_project_yml EXIT
  trap 'exit 130' INT TERM
  set_project_version "$PROJECT_FILE" "$2" "$3"
}

keep_project_bump() {
  [[ -n "$PROJECT_BACKUP" ]] && rm -f "$PROJECT_BACKUP"
  PROJECT_BACKUP=""
}

restore_project_yml() {
  if [[ -n "$PROJECT_BACKUP" && -f "$PROJECT_BACKUP" ]]; then
    cp "$PROJECT_BACKUP" "$PROJECT_FILE"
    rm -f "$PROJECT_BACKUP"
    PROJECT_BACKUP=""
    echo "↺ project.yml auf den alten Stand zurückgesetzt (nichts veröffentlicht)" >&2
  fi
}

# Vorhandenen Appcast vom Hub (<url>) nach <ziel> holen und die Quelle ausgeben. Ist er nicht
# lesbar (Hub oder Container aus, 404, kein gültiges XML), bricht der Release ab: ohne den Stand
# des Hubs ist nicht gesichert, dass die neue Build-Nummer über allen veröffentlichten liegt, und
# der Upload würde den Appcast des Hubs ersetzen. Eine lokale Kopie vom letzten Release zählt
# nicht. Nur mit <neu>=1 (--first, erster Release) beginnt dann ein neuer, leerer
# Appcast; ein lesbarer Hub-Appcast wird auch damit nie verworfen.
fetch_appcast() {
  local url="$1" dest="$2" allow_new="$3"
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL "$url" -o "$dest.remote" 2>/dev/null && xmllint --noout "$dest.remote" 2>/dev/null; then
    mv "$dest.remote" "$dest"
    echo "Hub"
    return 0
  fi
  rm -f "$dest.remote"
  if [[ "$allow_new" == "1" ]]; then
    rm -f "$dest"
    echo "neu (--first)"
    return 0
  fi
  echo "✗ Hub-Appcast nicht lesbar (${url}) – Abbruch, nichts verändert." >&2
  echo "  Erst den Hub prüfen. Nur für den ersten Release (noch kein Appcast auf dem Hub):" >&2
  echo "  scripts/release.sh --first <version> \"<Release-Notes>\"" >&2
  return 1
}

escape_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | awk 'BEGIN { ORS = "" } { if (NR > 1) print "<br>"; print }'
}

# Nur Funktionen, wenn die Datei per `source` geladen wird.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

# --- Ablauf -------------------------------------------------------------------------------------
set -euo pipefail

NEW_APPCAST=0
VERSION=""
NOTES=""
POSITIONAL=0
for arg in "$@"; do
  case "$arg" in
    --first) NEW_APPCAST=1 ;;
    *)
      POSITIONAL=$((POSITIONAL + 1))
      case "$POSITIONAL" in
        1) VERSION="$arg" ;;
        2) NOTES="$arg" ;;
      esac
      ;;
  esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [[ -z "$NOTES" ]] || (( POSITIONAL != 2 )); then
  echo "Aufruf: scripts/release.sh [--first] <version, z. B. 0.2.0> \"<Release-Notes>\"" >&2
  echo "  --first nur für den ersten Release: legt einen neuen Appcast an, wenn der Hub keinen liefert." >&2
  exit 64
fi

ROOT="$_RELEASE_ROOT"
cd "$ROOT"
PROJECT_YML="$_PROJECT_YML"
[[ -n "$HUB_URL" ]] || { echo "✗ ULTRADIC_HUB_URL fehlt (BlitztextMac/project.yml)" >&2; exit 1; }

SPARKLE_VERSION="2.10.0"
SPARKLE_HOME="$HOME/Library/Caches/ultradic-sparkle/Sparkle-$SPARKLE_VERSION"
DIST="$HOME/Library/Caches/blitztext-build/dist"
MIN_MACOS="14.0"
PLACEHOLDER_KEY="REPLACE_WITH_PUBLIC_ED_KEY"

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*" >&2; }

# --- 1. Vorhandenen Appcast vom Hub holen (sonst Abbruch, außer --first) ---------------
APPCAST="$DIST/appcast.xml"
APPCAST_SOURCE="$(fetch_appcast "$HUB_URL/updates/appcast.xml" "$APPCAST" "$NEW_APPCAST")" || exit 1
if [[ "$NEW_APPCAST" == "1" && "$APPCAST_SOURCE" == "Hub" ]]; then
  echo "⚠ --first nicht nötig: der Hub liefert einen Appcast, der wird fortgeführt." >&2
elif [[ "$APPCAST_SOURCE" != "Hub" ]]; then
  echo "⚠ Hub-Appcast nicht lesbar – lege wie verlangt (--first) einen neuen an." >&2
fi

# --- 2. Sparkle-Werkzeuge (einmalig aus dem Release-Tarball) -------------------------------
if [[ ! -x "$SPARKLE_HOME/bin/sign_update" ]]; then
  step "Sparkle $SPARKLE_VERSION laden nach $SPARKLE_HOME"
  mkdir -p "$SPARKLE_HOME"
  TARBALL="$(mktemp -t sparkle).tar.xz"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$TARBALL"
  tar -xJf "$TARBALL" -C "$SPARKLE_HOME"
  rm -f "$TARBALL"
fi
[[ -x "$SPARKLE_HOME/bin/sign_update" ]] || fail "sign_update fehlt in $SPARKLE_HOME/bin"

# --- 3. Öffentlicher EdDSA-Schlüssel -----------------------------------------------------------
# Reihenfolge: Umgebung → project.yml (Platzhalter zählt nicht) → Schlüsselbund (generate_keys -p).
PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
if [[ -z "$PUBLIC_KEY" ]]; then
  PUBLIC_KEY="$(sed -n 's/^    SPARKLE_PUBLIC_KEY: "\(.*\)"$/\1/p' "$PROJECT_YML" | head -1)"
fi
if [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == "$PLACEHOLDER_KEY" ]]; then
  PUBLIC_KEY="$("$SPARKLE_HOME/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null | tail -1 || true)"
fi
if [[ -z "$PUBLIC_KEY" ]]; then
  fail "Kein Sparkle-Schlüssel gefunden. Einmalig anlegen (privater Teil bleibt im Schlüsselbund):
  $SPARKLE_HOME/bin/generate_keys --account $SPARKLE_ACCOUNT
  dann den ausgegebenen öffentlichen Schlüssel als SPARKLE_PUBLIC_KEY in BlitztextMac/project.yml eintragen."
fi

# --- 4. Build-Nummer: größer als project.yml und als alles im Appcast ----------------------------
CURRENT_BUILD="$(read_project_build "$PROJECT_YML")"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION in BlitztextMac/project.yml nicht lesbar"
APPCAST_MAX="$(max_appcast_build "$APPCAST")"
NEW_BUILD="$(next_build_number "$CURRENT_BUILD" "$APPCAST_MAX")"
(( NEW_BUILD > APPCAST_MAX && NEW_BUILD > CURRENT_BUILD )) \
  || fail "Build $NEW_BUILD ist nicht größer als project.yml ($CURRENT_BUILD) und Appcast ($APPCAST_MAX)"
step "Version $VERSION, Build $NEW_BUILD (project.yml: $CURRENT_BUILD, höchster im Appcast [$APPCAST_SOURCE]: $APPCAST_MAX)"
begin_project_bump "$PROJECT_YML" "$VERSION" "$NEW_BUILD"

# --- 5. Signatur-Identität ---------------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY_NAME\""; then
  SIGN_IDENTITY="$IDENTITY_NAME"
else
  SIGN_IDENTITY="-"
  cat >&2 <<'WARN'
⚠⚠⚠ WARNUNG: Identität „UltraDic Signing“ nicht gefunden – signiere AD-HOC.
    Updates funktionieren (EdDSA trägt die Sicherheit), aber macOS behandelt jede Version
    als neue App: Mikrofon- und Bedienungshilfen-Freigaben werden nach dem Update neu abgefragt.
    Einmalig beheben: scripts/setup-signing.sh
WARN
fi

# --- 6. Release-Build und Code-Signatur ----------------------------------------------------------
step "Release-Build"
# build.sh writes the signed app to $ROOT/UltraDic.app. The identity is passed explicitly;
# "-" is ad-hoc (build.sh would otherwise pick a local identity such as "Blitztext Dev").
ULTRADIC_CODESIGN_IDENTITY="$SIGN_IDENTITY" SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" "$ROOT/build.sh" --release >&2
APP="$ROOT/UltraDic.app"
[[ -d "$APP" ]] || fail "Build lieferte keine App ($APP)"
codesign --verify --deep --strict "$APP" || fail "Code-Signatur von $APP ungültig"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
BUILT_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" && "$BUILT_BUILD" == "$NEW_BUILD" ]] || fail "App hat $BUILT_VERSION ($BUILT_BUILD) statt $VERSION ($NEW_BUILD)"
[[ "$BUILT_KEY" == "$PUBLIC_KEY" ]] || fail "SUPublicEDKey im Bundle passt nicht zum Schlüssel"
BUILT_FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist")"
[[ "$BUILT_FEED" == "$HUB_URL/updates/appcast.xml" ]] || fail "SUFeedURL im Bundle ($BUILT_FEED) passt nicht zu HUB_URL ($HUB_URL)"

# --- 7. ZIP + EdDSA-Signatur -------------------------------------------------------------------------
ZIP_NAME="UltraDic-$VERSION.zip"
ZIP="$DIST/$ZIP_NAME"
rm -f "$ZIP"
step "ZIP $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SIGNATURE_ATTRS="$("$SPARKLE_HOME/bin/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP")"
[[ "$SIGNATURE_ATTRS" == *"sparkle:edSignature="* ]] || fail "sign_update lieferte keine Signatur: $SIGNATURE_ATTRS"
cp "$ZIP" "$DIST/latest.zip"

# Build und Signaturen sind gut: ab hier bleibt project.yml hochgezählt.
keep_project_bump
step "BlitztextMac/project.yml bleibt auf $VERSION ($NEW_BUILD)"

# --- 8. appcast.xml ergänzen ------------------------------------------------------------------------
if [[ ! -f "$APPCAST" ]]; then
  cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>UltraDic</title>
    <link>$HUB_URL/updates/appcast.xml</link>
    <description>Updates für UltraDic</description>
    <language>de</language>
  </channel>
</rss>
XML
fi
grep -q "<sparkle:version>$NEW_BUILD</sparkle:version>" "$APPCAST" && fail "Appcast enthält Build $NEW_BUILD schon"

NOTES_HTML="$(printf '%s' "$NOTES" | escape_html)"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
ITEM_FILE="$(mktemp -t appcast-item)"
cat > "$ITEM_FILE" <<XML
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <description><![CDATA[<h2>UltraDic $VERSION</h2><p>$NOTES_HTML</p>]]></description>
      <enclosure url="$HUB_URL/updates/$ZIP_NAME" type="application/octet-stream" $SIGNATURE_ATTRS />
    </item>
XML
# Newest item first: insert before the first <item>, or before </channel> if there is none.
awk -v itemfile="$ITEM_FILE" '
  BEGIN { while ((getline line < itemfile) > 0) item = item line "\n" }
  !done && ($0 ~ /<item>/ || $0 ~ /<\/channel>/) { printf "%s", item; done = 1 }
  { print }
' "$APPCAST" > "$APPCAST.new"
mv "$APPCAST.new" "$APPCAST"
rm -f "$ITEM_FILE"
xmllint --noout "$APPCAST" 2>/dev/null || fail "appcast.xml ist kein gültiges XML ($APPCAST)"
[[ "$(max_appcast_build "$APPCAST")" == "$NEW_BUILD" ]] || fail "Build $NEW_BUILD ist nicht der höchste im neuen Appcast"

# --- 9. Upload (Archive zuerst, Appcast zuletzt) ---------------------------------------------------
step "Upload nach $UPLOAD_TARGET"
scp -O "$ZIP" "$DIST/latest.zip" "$UPLOAD_TARGET"
scp -O "$APPCAST" "$UPLOAD_TARGET"

# --- 10. Prüfen, dass der Hub die neue Version ausliefert -------------------------------------------
step "Prüfe $HUB_URL/updates/appcast.xml"
curl -fsSL "$HUB_URL/updates/appcast.xml" | grep -q "<sparkle:version>$NEW_BUILD</sparkle:version>" \
  || fail "Hub-Appcast nennt Build $NEW_BUILD nicht"
REMOTE_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$HUB_URL/updates/$ZIP_NAME")"
[[ "$REMOTE_STATUS" == "200" || "$REMOTE_STATUS" == "206" ]] || fail "$HUB_URL/updates/$ZIP_NAME antwortet mit $REMOTE_STATUS"

echo "✓ UltraDic $VERSION ($NEW_BUILD) veröffentlicht – signiert mit: $SIGN_IDENTITY" >&2
echo "  Jetzt BlitztextMac/project.yml committen (Version $VERSION, Build $NEW_BUILD)." >&2
