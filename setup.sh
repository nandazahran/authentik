#!/usr/bin/env bash
# setup.sh - install Docker (official apt repo) and deploy Authentik
# Target: fresh Debian 12/13 or Ubuntu 22.04+ VM
# Usage:  sudo ./setup.sh [--harden] [--demo]
#   --harden  also configure ufw, unattended-upgrades and fail2ban
#   --demo    also deploy Caddy (HTTPS reverse proxy) + IT-Tools + Memos
#             (needs Caddyfile and docker-compose.override.yml next to this script)
#
# The script is idempotent: re-running it will not regenerate secrets
# or overwrite existing config files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/authentik"
COMPOSE_URL="https://goauthentik.io/docker-compose.yml"
HTTP_PORT=9000
HARDEN=false
DEMO=false

for arg in "$@"; do
  case "$arg" in
    --harden) HARDEN=true ;;
    --demo)   DEMO=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. preflight
log "1/5 Preflight checks"

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo ./setup.sh"

. /etc/os-release
case "${ID}" in
  debian|ubuntu) ;;
  *) die "Unsupported OS: ${ID} (need Debian or Ubuntu)" ;;
esac
echo "OS: ${PRETTY_NAME}"

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 1900 ] || die "Need at least ~2 GB RAM (found ${mem_mb} MB)"
echo "RAM: ${mem_mb} MB"
if [ "$DEMO" = true ] && [ "$mem_mb" -lt 2800 ]; then
  echo "Warning: ~3 GB RAM is recommended when running with --demo."
fi

disk_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
[ "$disk_gb" -ge 10 ] || die "Need at least 10 GB free disk (found ${disk_gb} GB)"
echo "Free disk: ${disk_gb} GB"

if [ "$DEMO" = true ]; then
  [ -f "${SCRIPT_DIR}/Caddyfile" ] || die "Caddyfile not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/docker-compose.override.yml" ] || die "docker-compose.override.yml not found next to setup.sh"
fi

# Only check ports on a first run (later runs would see our own containers)
if [ ! -f "${APP_DIR}/docker-compose.yml" ]; then
  ports_to_check=("${HTTP_PORT}")
  [ "$DEMO" = true ] && ports_to_check+=(80 443)
  for p in "${ports_to_check[@]}"; do
    if ss -ltn | grep -q ":${p} "; then
      die "Port ${p} is already in use"
    fi
  done
fi

# ------------------------------------------------------------ 2. install docker
log "2/5 Installing Docker from the official apt repository"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker and Compose plugin already installed, skipping."
else
  apt-get update
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
docker --version
docker compose version

# ----------------------------------------------------------------- 3. hardening
log "3/5 Base hardening"

if [ "$HARDEN" = true ]; then
  apt-get install -y ufw unattended-upgrades fail2ban

  # allow SSH BEFORE enabling the firewall so we don't lock ourselves out
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH || ufw allow 22/tcp
  if [ "$DEMO" = true ]; then
    # Caddy is the public entry point
    ufw allow 80/tcp
    ufw allow 443/tcp
  else
    ufw allow "${HTTP_PORT}"/tcp
    ufw allow 9443/tcp
  fi
  ufw --force enable

  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  systemctl enable --now fail2ban
  echo "Note: Docker-published ports can bypass ufw. Verify with nmap from another machine."
else
  echo "Skipped (run with --harden to enable ufw, unattended-upgrades, fail2ban)."
fi

# ---------------------------------------------------------- 4. deploy authentik
log "4/5 Deploying Authentik"

mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

if [ ! -f docker-compose.yml ]; then
  curl -fsSL -o docker-compose.yml "${COMPOSE_URL}"
else
  echo "docker-compose.yml already present, keeping it."
fi

if [ ! -f .env ]; then
  umask 077
  {
    echo "PG_PASS=$(openssl rand -base64 36 | tr -d '\n')"
    echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')"
    echo "AUTHENTIK_ERROR_REPORTING__ENABLED=false"
  } > .env
  chmod 600 .env
  echo "Generated new secrets in ${APP_DIR}/.env"
else
  echo ".env already present, keeping existing secrets."
fi

if [ "$DEMO" = true ]; then
  for f in Caddyfile docker-compose.override.yml; do
    if [ ! -f "$f" ]; then
      cp "${SCRIPT_DIR}/${f}" "$f"
      echo "Copied ${f}"
    else
      echo "${f} already present, keeping it."
    fi
  done
fi

docker compose pull
docker compose up -d

# ------------------------------------------------------------------- 5. verify
log "5/5 Waiting for Authentik to become healthy"

ready=false
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${HTTP_PORT}/-/health/live/" || true)
  if [[ "$code" =~ ^2 ]]; then ready=true; break; fi
  printf '.'
  sleep 5
done
echo

if [ "$ready" = true ]; then
  ip=$(hostname -I | awk '{print $1}')
  log "Authentik is up"
  if [ "$DEMO" = true ]; then
    echo "1) On the machine running your browser, add this line to its hosts file:"
    echo "   ${ip}  auth-demo.lab.local tools-demo.lab.local memos-demo.lab.local"
    echo "2) Create the admin account (choose your own password) at:"
    echo "   https://auth-demo.lab.local/if/flow/initial-setup/"
    echo "   (the browser will warn about Caddy's local certificate authority)"
    echo "   Fallback without Caddy: http://${ip}:${HTTP_PORT}/if/flow/initial-setup/"
  else
    echo "Finish setup and create the admin account (choose your own password) at:"
    echo "  http://${ip}:${HTTP_PORT}/if/flow/initial-setup/"
  fi
else
  echo "Not healthy after 5 minutes. Check logs with:"
  echo "  cd ${APP_DIR} && docker compose logs --tail=100"
  exit 1
fi
