#!/usr/bin/env bash
# firstboot.sh — one-shot first-real-boot provisioning for the OpenClaw per-client VM.
#
# Runs ONCE via openclaw-firstboot.service (installed by the autoinstall snippet).
# Idempotent; disables itself at the end. Brings up the full stack:
#   openclaw-gateway (agent) + panel (CloudHosting setup UI) + caddy (TLS for the panel).
#
# Steps:
#   1. Ensure ./data (+ workspace, auth-profile-secrets) owned by the agent uid:gid.
#   2. Seed openclaw.json into ./data if absent (the gateway reads ~/.openclaw/openclaw.json).
#   3. Generate OPENCLAW_GATEWAY_TOKEN into ./data/.env if absent (openclaw.json refs it).
#   4. Derive PANEL_DOMAIN from the primary IPv4 if blank.
#   5. docker compose pull && up -d.
#   6. Install + enable the host-side applier (systemd path+service).
#   7. Disable this oneshot.
#
# Absolute paths (/opt/openclaw-vm) so this works regardless of cwd.

set -euo pipefail

APP_DIR="/opt/openclaw-vm"
DATA_DIR="${APP_DIR}/data"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
APPLIER_SRC="${APP_DIR}/applier"
APPLIER_LIB="/usr/local/lib/cloudhosting"
PANEL_ENV="/etc/cloudhosting-panel.env"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"

# --- Load compose-level .env (PANEL_DOMAIN etc.); OPENCLAW_UID/GID overridable -----
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && set -a && . "${ENV_FILE}" && set +a || true

OPENCLAW_UID="${OPENCLAW_UID:-1000}"   # the image's node user
OPENCLAW_GID="${OPENCLAW_GID:-1000}"

# --- 1. Shared data dir + subdirs: owner = agent uid:gid (panel runs as it too) -----
log "Ensuring ${DATA_DIR} (owner ${OPENCLAW_UID}:${OPENCLAW_GID})"
mkdir -p "${DATA_DIR}/workspace" "${DATA_DIR}/auth-profile-secrets"
chown -R "${OPENCLAW_UID}:${OPENCLAW_GID}" "${DATA_DIR}"
chmod 0750 "${DATA_DIR}"

# --- 2. Seed openclaw.json the gateway reads (don't clobber an existing one) ---------
if [ -f "${APP_DIR}/openclaw.json" ] && [ ! -f "${DATA_DIR}/openclaw.json" ]; then
  log "Seeding openclaw.json into data dir"
  cp "${APP_DIR}/openclaw.json" "${DATA_DIR}/openclaw.json"
  chown "${OPENCLAW_UID}:${OPENCLAW_GID}" "${DATA_DIR}/openclaw.json"
  chmod 0600 "${DATA_DIR}/openclaw.json"
fi

# --- 3. Generate the gateway token into ./data/.env if absent -----------------------
# openclaw.json references ${OPENCLAW_GATEWAY_TOKEN}; OpenClaw resolves it from
# ~/.openclaw/.env. The panel preserves this key on every rewrite.
touch "${DATA_DIR}/.env"
if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=' "${DATA_DIR}/.env" 2>/dev/null; then
  TOKEN="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "${TOKEN}" >> "${DATA_DIR}/.env"
  log "Generated OPENCLAW_GATEWAY_TOKEN"
fi
chown "${OPENCLAW_UID}:${OPENCLAW_GID}" "${DATA_DIR}/.env"
chmod 0600 "${DATA_DIR}/.env"

# --- 4. Derive PANEL_DOMAIN from the primary IPv4 if blank --------------------------
if [ -z "${PANEL_DOMAIN:-}" ]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1)"
  [ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${IP}" ] || die "could not determine primary IPv4 to derive PANEL_DOMAIN"
  O3="$(printf '%s' "${IP}" | cut -d. -f3)"
  O4="$(printf '%s' "${IP}" | cut -d. -f4)"
  PANEL_DOMAIN="vps-${O3}-${O4}.cloudhosting.lv"
  log "Derived PANEL_DOMAIN=${PANEL_DOMAIN} from IP ${IP}"
  if grep -q '^PANEL_DOMAIN=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN}|" "${ENV_FILE}"
  else
    printf 'PANEL_DOMAIN=%s\n' "${PANEL_DOMAIN}" >> "${ENV_FILE}"
  fi
  export PANEL_DOMAIN
else
  log "PANEL_DOMAIN already set: ${PANEL_DOMAIN}"
fi

# --- 5. Pull + start the stack ------------------------------------------------------
log "docker compose pull"
docker compose -f "${COMPOSE_FILE}" pull
log "docker compose up -d"
docker compose -f "${COMPOSE_FILE}" up -d

# --- 6. Install the host-side applier ------------------------------------------------
log "Installing applier units"
install -d -m 0755 "${APPLIER_LIB}"
install -m 0755 "${APPLIER_SRC}/apply.sh" "${APPLIER_LIB}/apply.sh"
cp "${APPLIER_SRC}/cloudhosting-applier.path"    /etc/systemd/system/
cp "${APPLIER_SRC}/cloudhosting-applier.service" /etc/systemd/system/
cat > "${PANEL_ENV}" <<EOF
PRODUCT=openclaw
COMPOSE_FILE=${COMPOSE_FILE}
COMPOSE_PROJECT_DIR=${APP_DIR}
DATA_DIR=${DATA_DIR}
EOF
chmod 0644 "${PANEL_ENV}"
systemctl daemon-reload
systemctl enable --now cloudhosting-applier.path
log "Applier enabled (watching ${DATA_DIR}/.apply-request)"

# --- 7. Disable this oneshot --------------------------------------------------------
log "Disabling openclaw-firstboot.service (provisioning complete)"
systemctl disable openclaw-firstboot.service 2>/dev/null || true

log "First boot complete. Panel: https://${PANEL_DOMAIN}:8443"
