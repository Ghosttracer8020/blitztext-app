#!/bin/bash
# Deploys the UltraDic hub to the NAS (/volume1/docker/ultradic-hub).
#
#   distribution/hub/scripts/deploy.sh            # serve port 8452
#   PORT=8453 distribution/hub/scripts/deploy.sh
#
# Steps: backup -> tar of the sources -> scp -O -> extract -> docker compose up -d --build
# (detached, health poll, rollback to the previous image on failure) -> tailscale serve
# https PORT -> 127.0.0.2:3013 -> check via the Tailnet -> check that the direct path
# http://100.86.159.70:3013 is closed (userspace tailscaled forwards direct Tailnet
# connections to 127.0.0.1 only; on that path identity headers could be forged).
#
# Never copies or deletes data/ (updates archive).
set -euo pipefail

cd "$(dirname "$0")/.."
HUB_DIR="$(pwd)"
PORT="${PORT:-8452}"
STACK=/volume1/docker/ultradic-hub
CONTAINER=ultradic-hub
IMAGE=ultradic-hub
PUBLIC_URL="https://ugreen-nas.tail076274.ts.net:$PORT"
STAMP="$(date +%Y%m%d-%H%M%S)"
GIT_SHA="$(git -C "$HUB_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

nas() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 claudedude@100.86.159.70 "$@"
}

say() { printf '[deploy] %s\n' "$*"; }

# Back to $IMAGE:previous with the compose files from this deploy's backup.
rollback() {
  if nas "docker image inspect $IMAGE:previous >/dev/null 2>&1"; then
    say "Rückfall auf $IMAGE:previous"
    if ! nas "set -e; cd $STACK
      if [ -f /home/claudedude/backups/ultradic-hub-$STAMP.tar.gz ]; then
        tar xzf /home/claudedude/backups/ultradic-hub-$STAMP.tar.gz --no-same-owner --exclude=./data
      fi
      docker tag $IMAGE:previous $IMAGE:latest
      docker compose up -d --no-build --force-recreate"; then
      say "FEHLER: Rückfall fehlgeschlagen – Hub läuft möglicherweise nicht mehr, bitte sofort Logs prüfen"
      exit 1
    fi
    sleep 20
    say "Zustand nach Rückfall: $(nas "docker inspect --format '{{.State.Health.Status}}' $CONTAINER 2>/dev/null || echo missing")"
  else
    say "Kein Rückfall-Image vorhanden (Erst-Deploy) – bitte Logs prüfen."
  fi
}

if [ -n "$(git -C "$HUB_DIR" status --porcelain -- . 2>/dev/null)" ]; then
  say "WARNUNG: hub/ hat uncommittete Änderungen – deployt wird der Stand auf der Platte (GIT_SHA=$GIT_SHA)."
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
COPYFILE_DISABLE=1 tar czf "$STAGE/hub.tar.gz" -C "$HUB_DIR" \
  package.json package-lock.json tsconfig.json tsconfig.build.json \
  Dockerfile docker-compose.yml .dockerignore src
say "Paket: $(du -h "$STAGE/hub.tar.gz" | cut -f1), GIT_SHA=$GIT_SHA, Port $PORT"

say "1/6 Backup auf dem NAS"
nas "set -e; mkdir -p /home/claudedude/backups
  if [ -f $STACK/docker-compose.yml ]; then
    cd $STACK && tar czf /home/claudedude/backups/ultradic-hub-$STAMP.tar.gz \
      --exclude=./data/updates . \
      && echo '[deploy] Backup: /home/claudedude/backups/ultradic-hub-$STAMP.tar.gz'
    if docker image inspect $IMAGE:latest >/dev/null 2>&1; then
      docker tag $IMAGE:latest $IMAGE:previous && echo '[deploy] Rückfall-Image: $IMAGE:previous'
    fi
  else
    echo '[deploy] Erst-Deploy: nichts zu sichern'
  fi"

say "2/6 Übertragen und entpacken"
scp -O "$STAGE/hub.tar.gz" claudedude@100.86.159.70:/tmp/ultradic-hub.tar.gz
nas "set -e; mkdir -p $STACK/data/updates && cd $STACK
  rm -rf src
  tar xzf /tmp/ultradic-hub.tar.gz --no-same-owner && rm /tmp/ultradic-hub.tar.gz
  find . -name '._*' -not -path './data/*' -delete"

LOG=/home/claudedude/ultradic-hub-build.log
say "3/6 Build und Start (abgekoppelt, Log: $LOG)"
nas "cd $STACK && rm -f $LOG && { GIT_SHA=$GIT_SHA HUB_URL=$PUBLIC_URL nohup sh -c 'docker compose up -d --build; echo \"compose-exit=\$?\"' > $LOG 2>&1 < /dev/null & } && echo '[deploy] gestartet'"

say "4/6 Warten auf den Build (bis 15 min)"
exit_line=""
for i in $(seq 1 90); do
  sleep 10
  exit_line="$(nas "grep -o 'compose-exit=[0-9]*' $LOG 2>/dev/null || true")"
  [ -n "$exit_line" ] && break
  if [ $((i % 6)) -eq 0 ]; then say "… Build läuft seit $((i / 6)) min"; fi
done
if [ -z "$exit_line" ]; then
  say "FEHLER: Build nach 15 min nicht fertig. Er läuft auf dem NAS weiter; Log: $LOG"
  exit 1
fi
if [ "$exit_line" != "compose-exit=0" ]; then
  say "FEHLER: docker compose gescheitert ($exit_line). Letzte Log-Zeilen:"
  nas "tail -n 40 $LOG"
  # A failed build leaves the old container alone; a failed start after the
  # build has already removed it. Decide by what is actually running.
  running="$(nas "docker inspect --format '{{.State.Running}}' $CONTAINER 2>/dev/null || echo false")"
  running_image="$(nas "docker inspect --format '{{.Image}}' $CONTAINER 2>/dev/null || true")"
  previous_image="$(nas "docker image inspect --format '{{.Id}}' $IMAGE:previous 2>/dev/null || true")"
  if [ "$running" = true ] && [ -n "$previous_image" ] && [ "$running_image" = "$previous_image" ]; then
    say "Der bisherige Container läuft unverändert weiter."
  elif [ "$running" = true ]; then
    say "Es läuft ein Container, aber nicht mit dem bisherigen Image – bitte Logs prüfen."
  else
    say "Kein laufender Container mehr."
    rollback
  fi
  exit 1
fi

state=missing
for _ in $(seq 1 24); do
  state="$(nas "docker inspect --format '{{.State.Health.Status}}' $CONTAINER 2>/dev/null || echo missing")"
  [ "$state" = healthy ] && break
  sleep 5
done
if [ "$state" != healthy ]; then
  say "FEHLER: neuer Container nicht healthy (Zustand: $state). Letzte Log-Zeilen:"
  nas "docker logs --tail 40 $CONTAINER 2>&1 || true"
  rollback
  exit 1
fi
say "Container healthy (GIT_SHA=$GIT_SHA)"

say "5/6 tailscale serve für Port $PORT"
# Refuse to overwrite a serve rule that belongs to another tool (e.g. a different
# port owner on the shared NAS): `serve --https=PORT` replaces an existing rule silently.
serve_status="$(nas "docker exec tailscale tailscale serve status 2>/dev/null || true")"
owner="$(printf '%s\n' "$serve_status" | awk -v port=":$PORT" '
  /^https?:\/\// { inblk = (index($1, port) > 0 && $1 ~ port "$") ; next }
  inblk && /proxy/ { print $NF }')"
if [ -n "$owner" ] && [ "$owner" != "http://127.0.0.2:3013" ]; then
  say "FEHLER: Port $PORT ist auf dem NAS bereits vergeben ($owner). Anderen Port wählen: PORT=<frei> $0"
  exit 1
fi
nas "docker exec tailscale tailscale serve --bg --https=$PORT http://127.0.0.2:3013 >/dev/null && echo '[deploy] serve $PORT → 127.0.0.2:3013'"

say "6/6 Prüfung über das Tailnet"
# The direct path must be closed, otherwise anyone in the Tailnet can forge Tailscale-User-Login.
if curl -s -o /dev/null --max-time 5 "http://100.86.159.70:3013/api/health"; then
  say "FEHLER: Hub ist direkt über http://100.86.159.70:3013 erreichbar – Identität fälschbar. Container wird gestoppt."
  nas "cd $STACK && docker compose stop"
  exit 1
fi
say "Direkter Weg http://100.86.159.70:3013 ist zu (gut)."
body="$(curl -fsS --max-time 15 "$PUBLIC_URL/api/health")" || { say "FEHLER: $PUBLIC_URL/api/health nicht erreichbar"; exit 1; }
say "$PUBLIC_URL/api/health → $body"
case "$body" in
  *'"ok":true'*) say "OK – Hub läuft." ;;
  *) say "FEHLER: Health meldet nicht ok"; exit 1 ;;
esac
