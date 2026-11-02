#!/usr/bin/env bash
# Teiltests für scripts/release.sh, ohne Build, Netz oder Upload: lädt dessen Funktionen per
# `source` und prüft Build-Nummer, Zurücksetzen von project.yml, Abruf des Hub-Appcasts und
# HTML-Escaping an Kopien in einem Temp-Ordner. Dazu zwei Läufe des ganzen Skripts in einer
# Kopie ohne Hub (mit Attrappen statt Sparkle-Werkzeugen, ohne build.sh, Upload-Ziel lokal).
#   scripts/test-release.sh
# Jede Prüfung meldet ✔ oder ✘. Eine einzige ✘ macht den Lauf rot (exit 1), auch wenn die
# Prüfung in einer Subshell lief.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release.sh
source "$ROOT/scripts/release.sh"

WORK="$(mktemp -d -t ultradic-release-test)"
trap 'rm -rf "$WORK"' EXIT
# Failures go to a file, not a variable: a check in a subshell counts as well.
FAILURES="$WORK/fehlgeschlagen"
: > "$FAILURES"
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "✔ ${name}"
  else
    echo "✘ ${name}: erwartet »${expected}«, erhalten »${actual}«"
    echo "${name}" >> "$FAILURES"
  fi
}
checksum() { if [[ -f "$1" ]]; then shasum < "$1" | cut -d' ' -f1; fi; }

# --- Hub-URL: einzige Quelle ist project.yml ---
check "HUB_URL stammt aus project.yml (ULTRADIC_HUB_URL)" \
  "$(sed -n 's/^    ULTRADIC_HUB_URL: "\(.*\)"$/\1/p' "$ROOT/BlitztextMac/project.yml")" "${ULTRADIC_HUB_URL:-$HUB_URL}"
check "HUB_URL nicht leer" 1 "$([[ -n "$HUB_URL" ]] && echo 1 || echo 0)"

# --- höchste Build-Nummer im Appcast ---
cat > "$WORK/appcast.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
  <item><sparkle:version>12</sparkle:version><sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion></item>
  <item><sparkle:version>5</sparkle:version></item>
  <item><enclosure url="x" sparkle:version="9" sparkle:shortVersionString="0.2.0" /></item>
</channel></rss>
XML
check "Appcast: höchste Build-Nummer (Element und Attribut)" 12 "$(max_appcast_build "$WORK/appcast.xml")"
printf '<rss><channel></channel></rss>\n' > "$WORK/leer.xml"
check "Appcast ohne Einträge → 0" 0 "$(max_appcast_build "$WORK/leer.xml")"
check "kein Appcast → 0" 0 "$(max_appcast_build "$WORK/fehlt.xml")"

# --- nächste Build-Nummer ---
check "project.yml hinter dem Appcast (Review-Fall 3 vs. 5)" 6 "$(next_build_number 3 5)"
check "project.yml vor dem Appcast" 8 "$(next_build_number 7 5)"
check "gleichstand" 6 "$(next_build_number 5 5)"
check "erster Release" 2 "$(next_build_number 1 0)"

# --- project.yml: vorläufig hochzählen, bei Fehler zurücksetzen ---
cp "$ROOT/BlitztextMac/project.yml" "$WORK/project.yml"
ORIGINAL="$(checksum "$WORK/project.yml")"
# A failing release (set -e) after the bump: the EXIT trap restores the file. The value seen
# during the run is written out and checked here, outside the subshell, so a subshell that
# dies early shows up as ✘ instead of a missing line.
( set -e; begin_project_bump "$WORK/project.yml" "9.9.9" "999"
  read_project_build "$WORK/project.yml" > "$WORK/waehrend.txt"
  false ) 2>/dev/null
check "während des Laufs hochgezählt" 999 "$(cat "$WORK/waehrend.txt" 2>/dev/null)"
check "Fehler vor Build/Signatur → project.yml unverändert" "$ORIGINAL" "$(checksum "$WORK/project.yml")"
# Success: keep_project_bump keeps the new values.
( set -e; begin_project_bump "$WORK/project.yml" "9.9.9" "999"; keep_project_bump; false ) 2>/dev/null
check "nach Build + Signatur bleibt die Build-Nummer" 999 "$(read_project_build "$WORK/project.yml")"
check "… und die Version" 1 "$(grep -c '^    MARKETING_VERSION: "9.9.9"$' "$WORK/project.yml")"

# --- Appcast vom Hub: nicht lesbar → Abbruch, außer --first ---
mkdir -p "$WORK/hub/updates" "$WORK/dist"
cp "$WORK/appcast.xml" "$WORK/hub/updates/appcast.xml"
printf '<!doctype html><title>502</title><h1>502 Bad Gateway</h1>\n' > "$WORK/hub/updates/gateway.html"
HUB_OK="file://$WORK/hub/updates/appcast.xml"
HUB_DOWN="file://$WORK/kein-hub/updates/appcast.xml"
DEST="$WORK/dist/appcast.xml"

SOURCE="$(fetch_appcast "$HUB_OK" "$DEST" 0)"; STATUS=$?
check "Hub lesbar → Quelle Hub" "0 Hub" "$STATUS $SOURCE"
check "… Appcast übernommen" "$(checksum "$WORK/appcast.xml")" "$(checksum "$DEST")"

printf '<rss><channel><item><sparkle:version>3</sparkle:version></item></channel></rss>\n' > "$DEST"
STALE="$(checksum "$DEST")"
SOURCE="$(fetch_appcast "$HUB_DOWN" "$DEST" 0 2>/dev/null)"; STATUS=$?
check "Hub nicht lesbar → Abbruch, auch mit lokaler Kopie" "1 " "$STATUS $SOURCE"
check "… lokale Kopie weder benutzt noch verändert" "$STALE" "$(checksum "$DEST")"
check "… keine halbe Datei übrig" 0 "$(find "$WORK/dist" -name '*.remote' | wc -l | tr -d ' ')"

SOURCE="$(fetch_appcast "file://$WORK/hub/updates/gateway.html" "$DEST" 0 2>/dev/null)"; STATUS=$?
check "Hub antwortet mit HTML statt Appcast → Abbruch" 1 "$STATUS"

SOURCE="$(fetch_appcast "$HUB_DOWN" "$DEST" 1)"; STATUS=$?
check "Hub nicht lesbar + --first → neuer Appcast" "0 neu (--first)" "$STATUS $SOURCE"
check "… alte lokale Kopie nicht übernommen" "fehlt" "$([[ -e "$DEST" ]] && echo da || echo fehlt)"

SOURCE="$(fetch_appcast "$HUB_OK" "$DEST" 1)"; STATUS=$?
check "Hub lesbar + --first → Hub-Appcast wird fortgeführt" "0 Hub" "$STATUS $SOURCE"

# --- Ganzer Lauf in einer Kopie ohne Hub ---
# Attrappen statt Sparkle-Werkzeugen (nichts wird geladen), kein build.sh in der Kopie (der Lauf
# endet spätestens beim Build), Upload-Ziel ein lokaler Ordner.
COPY="$WORK/repo"
FAKE_HOME="$WORK/home"
FAKE_SPARKLE="$FAKE_HOME/Library/Caches/ultradic-sparkle/Sparkle-2.10.0/bin"
mkdir -p "$COPY/scripts" "$COPY/BlitztextMac" "$FAKE_SPARKLE"
cp "$ROOT/scripts/release.sh" "$COPY/scripts/release.sh"
cp "$ROOT/BlitztextMac/project.yml" "$COPY/BlitztextMac/project.yml"
for tool in sign_update generate_keys; do
  printf '#!/bin/sh\necho "Attrappe %s" >&2\nexit 1\n' "$tool" > "$FAKE_SPARKLE/$tool"
  chmod +x "$FAKE_SPARKLE/$tool"
done
run_release() {
  HOME="$FAKE_HOME" ULTRADIC_HUB_URL="file://$WORK/kein-hub" ULTRADIC_UPLOAD_TARGET="$WORK/upload/" \
    SPARKLE_PUBLIC_KEY="test-key" "$BASH" "$COPY/scripts/release.sh" "$@" 2>&1
}

OUTPUT="$(run_release 0.2.0 "Test")"; STATUS=$?
check "release.sh ohne Hub-Appcast: exit 1" 1 "$STATUS"
check "… mit Meldung" 1 "$(grep -c 'Hub-Appcast nicht lesbar' <<<"$OUTPUT")"
check "… vor Sparkle-Download, Build-Nummer, Signatur-Identität und Build" 0 \
  "$(grep -cE 'Sparkle .* laden|Build [0-9]+ \(project|WARNUNG: Identität|Release-Build' <<<"$OUTPUT")"
check "… project.yml unverändert" "$(checksum "$ROOT/BlitztextMac/project.yml")" "$(checksum "$COPY/BlitztextMac/project.yml")"

OUTPUT="$(run_release --first 0.2.0 "Test")"; STATUS=$?
check "release.sh --first ohne Hub: läuft bis zum Build" 1 "$(grep -c '▸ Release-Build' <<<"$OUTPUT")"
check "… scheitert in der Kopie am fehlenden build.sh" "nicht 0" "$([[ $STATUS -eq 0 ]] && echo 0 || echo "nicht 0")"
check "… project.yml zurückgesetzt" "$(checksum "$ROOT/BlitztextMac/project.yml")" "$(checksum "$COPY/BlitztextMac/project.yml")"
check "… nichts hochgeladen" "fehlt" "$([[ -e "$WORK/upload" ]] && echo da || echo fehlt)"

check "Aufruf mit drei Argumenten → Aufrufhilfe (exit 64)" 64 "$(run_release 0.2.0 "Test" extra >/dev/null; echo $?)"

check "keine Sicherungsdatei übrig" 0 "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ultradic-project-yml*' -newer "$WORK/appcast.xml" 2>/dev/null | wc -l | tr -d ' ')"

# --- Release-Notes ---
check "HTML-Escaping und Zeilenumbrüche" "a &lt;b&gt; &amp; c<br>zweite Zeile" "$(printf 'a <b> & c\nzweite Zeile' | escape_html)"

if bash -n "$ROOT/scripts/release.sh"; then echo "✔ bash -n release.sh"; else echo "✘ bash -n release.sh"; echo "bash -n" >> "$FAILURES"; fi

FAILED_COUNT="$(wc -l < "$FAILURES" | tr -d ' ')"
if (( FAILED_COUNT > 0 )); then
  echo "✘ ${FAILED_COUNT} Prüfung(en) fehlgeschlagen"
  exit 1
fi
echo "✔ alle Prüfungen bestanden"
