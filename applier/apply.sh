#!/usr/bin/env bash
# apply.sh — host-side applier for the OpenClaw per-client VM (CloudHosting AI Panel).
#
# The web panel container is UNPRIVILEGED: it can only WRITE the shared data volume
# and `touch <data>/.apply-request`. It cannot reach docker. This script runs ON THE
# HOST (via a systemd path unit watching .apply-request) and is the only thing allowed
# to drive docker compose. For OpenClaw this maps to:
#   docker compose -f /opt/openclaw-vm/docker-compose.yml restart openclaw-gateway
# so the agent re-reads the openclaw.json + .env the panel just wrote.
#
# Paths default to the OpenClaw layout but can be overridden via /etc/cloudhosting-panel.env:
#   PRODUCT openclaw ; COMPOSE_FILE ; COMPOSE_PROJECT_DIR ; DATA_DIR
# Idempotent and safe to re-run.

set -euo pipefail

ENV_FILE="${PANEL_APPLIER_ENV:-/etc/cloudhosting-panel.env}"
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}"

PRODUCT="${PRODUCT:-${1:-openclaw}}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/openclaw-vm/docker-compose.yml}"
DATA_DIR="${DATA_DIR:-/opt/openclaw-vm/data}"

log() { printf '[applier %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[applier ERROR] %s\n' "$*" >&2; exit 1; }

case "${PRODUCT}" in
  openclaw) SERVICE="openclaw-gateway" ;;
  *)        die "This applier is for PRODUCT=openclaw only (got '${PRODUCT}')." ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found on host."
docker compose version >/dev/null 2>&1 || die "docker compose v2 required."
[ -f "${COMPOSE_FILE}" ] || die "COMPOSE_FILE not found: ${COMPOSE_FILE}. Set it in ${ENV_FILE}."

PROJECT_DIR="${COMPOSE_PROJECT_DIR:-$(dirname "${COMPOSE_FILE}")}"

# NOTE: approving a user who messaged the bot is NOT an applier action for OpenClaw —
# access is the channel allowFrom (owner-lock) written by the panel into openclaw.json,
# so it reaches the applier as an ordinary config change -> plain restart.

CFG="${DATA_DIR}/openclaw.json"
[ -f "${CFG}" ] || log "WARN: expected config ${CFG} not found yet; restarting anyway so the agent re-reads .env."

log "PRODUCT=${PRODUCT} SERVICE=${SERVICE} COMPOSE_FILE=${COMPOSE_FILE}"
log "Restarting service '${SERVICE}' so it picks up the new config..."
docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" restart "${SERVICE}"
log "Restart issued for '${SERVICE}'. Done."
