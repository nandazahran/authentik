#!/usr/bin/env bash
# setup.sh - install Docker (official apt repo) and deploy Authentik
# Target: fresh Debian 12/13 or Ubuntu 22.04+ server (VPS with public IP, or
#         a local computer using Cloudflare Tunnel)
# Usage:  sudo ./setup.sh --vps <auth-host> <tools-host> <poznote-host> [--harden]
#         sudo ./setup.sh --tunnel <auth-host> <tools-host> <poznote-host> [--harden]
#   --vps    public deployment: Caddy with ACME certificates answers on
#            80/443 directly (needs a public IP + DNS records for the hosts)
#   --tunnel local deployment: ingress via Cloudflare Tunnel, no published
#            web port; the connector is activated later with the token
#   --harden also configure ufw, unattended-upgrades and fail2ban
#
# Requires (next to this script): Caddyfile (or Caddyfile.tunnel) and
# docker-compose.override.yml, plus docker-compose.vps.yml or
# docker-compose.tunnel.yml.
#
# The script starts only the private backends (server, worker, poznote) and
# never opens public ingress itself: admin accounts must be bootstrapped via
# SSH port-forward first. Caddy (and the tunnel connector) are started
# manually afterwards, as printed at the end of the run.
#
# The script is idempotent: re-running it will not regenerate secrets
# or overwrite existing config files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/authentik"
COMPOSE_URL="https://goauthentik.io/docker-compose.yml"
HTTP_PORT=9000
HARDEN=false
MODE=""

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

print_usage() {
  cat <<'EOF'
Usage: sudo ./setup.sh --vps|--tunnel <auth-host> <tools-host> <poznote-host> [--harden]

  --vps     VPS with a public IP: Caddy + ACME answers on 80/443 directly
  --tunnel  Local computer: ingress via Cloudflare Tunnel (no published web port)
  --harden  also configure ufw, unattended-upgrades and fail2ban

The three host arguments are the full public DNS hostnames, e.g.
  sudo ./setup.sh --vps auth.example.com tools.example.com poznote.example.com
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vps|--tunnel)
      [ -n "$MODE" ] && die "Pick one mode: --vps or --tunnel"
      MODE="${1#--}"
      shift
      ;;
    --harden)
      HARDEN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
    *)
      HOSTS+=("$1")
      shift
      ;;
  esac
done

[ -n "$MODE" ] || { print_usage; exit 1; }
if [ "${#HOSTS[@]}" -ne 3 ]; then
  print_usage
  die "Exactly three hostnames required: <auth-host> <tools-host> <poznote-host>"
fi
AUTH_HOST="${HOSTS[0]}"
TOOLS_HOST="${HOSTS[1]}"
POZNOTE_HOST="${HOSTS[2]}"


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
if [ "$mem_mb" -lt 2800 ]; then
  echo "Warning: ~3 GB RAM is recommended when running the demo apps."
fi

disk_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
[ "$disk_gb" -ge 10 ] || die "Need at least 10 GB free disk (found ${disk_gb} GB)"
echo "Free disk: ${disk_gb} GB"

[ -f "${SCRIPT_DIR}/docker-compose.override.yml" ] || die "docker-compose.override.yml not found next to setup.sh"
if [ "$MODE" = vps ]; then
  [ -f "${SCRIPT_DIR}/Caddyfile" ] || die "Caddyfile not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/docker-compose.vps.yml" ] || die "docker-compose.vps.yml not found next to setup.sh"
else
  [ -f "${SCRIPT_DIR}/Caddyfile.tunnel" ] || die "Caddyfile.tunnel not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/docker-compose.tunnel.yml" ] || die "docker-compose.tunnel.yml not found next to setup.sh"
fi


# Only check ports on a first run (later runs would see our own containers)
if [ ! -f "${APP_DIR}/docker-compose.yml" ]; then
  ports_to_check=("${HTTP_PORT}")
  [ "$MODE" = vps ] && ports_to_check+=(80 443)
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

# Both overlays use !override (server/poznote ports), which needs
# Compose >= 2.24.4. Checked AFTER installation so fresh hosts pass too.
compose_version=$(docker compose version --short 2>/dev/null | tr -dc '0-9.' || true)
lowest=$(printf '%s\n2.24.4\n' "$compose_version" | sort -V | head -1)
[ "$lowest" = "2.24.4" ] \
  || die "docker-compose.vps.yml/docker-compose.tunnel.yml need Compose >= 2.24.4 (found: ${compose_version:-unknown})"

# ----------------------------------------------------------------- 3. hardening
log "3/5 Base hardening"

if [ "$HARDEN" = true ]; then
  apt-get install -y ufw unattended-upgrades fail2ban

  # allow SSH BEFORE enabling the firewall so we don't lock ourselves out
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH || ufw allow 22/tcp
  if [ "$MODE" = vps ]; then
    # Caddy is the public entry point (ACME needs 80 + 443 inbound)
    ufw allow 80/tcp
    ufw allow 443/tcp
  else
    # Tunnel mode: no inbound web ports. cloudflared connects OUTBOUND to
    # Cloudflare on TCP/UDP 7844, already covered by 'default allow
    # outgoing' above — no inbound 7844 rule is needed or wanted.
    :
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

# Mode config: always add missing keys, never overwrite values the operator
# already set (idempotent on re-runs and safe on --harden-only re-runs).
add_env_key() {
  key="$1" value="$2"
  if ! grep -q "^${key}=" .env; then
    echo "${key}=${value}" >> .env
    echo "Added ${key} to .env"
  else
    echo "${key} already present in .env, keeping it."
  fi
}

if [ "$MODE" = vps ]; then
  OVERLAY="docker-compose.vps.yml"
  CADDY_FILE="Caddyfile"
else
  OVERLAY="docker-compose.tunnel.yml"
  CADDY_FILE="Caddyfile.tunnel"
fi

for f in docker-compose.override.yml "${OVERLAY}" "${CADDY_FILE}" blueprint.yaml; do
  if [ ! -f "$f" ]; then
    cp "${SCRIPT_DIR}/${f}" "$f"
    echo "Copied ${f}"
  else
    echo "${f} already present, keeping it."
  fi
done

# A stale/foreign COMPOSE_FILE must not silently win: if it does not select
# this mode's overlay, the base file publishes 9000/9443 on all interfaces.
current_compose_file=$(grep -E '^COMPOSE_FILE=' .env | tail -1 | cut -d= -f2- || true)
if [ -n "$current_compose_file" ] \
  && ! printf '%s' "$current_compose_file" | tr ':' '\n' | grep -qx "${OVERLAY}"; then
  die "COMPOSE_FILE in .env is '${current_compose_file}' and does not include ${OVERLAY}. Edit /opt/authentik/.env and set COMPOSE_FILE to select the intended overlay (docker-compose.yml:docker-compose.override.yml:${OVERLAY}), then re-run."
fi

add_env_key COMPOSE_FILE "docker-compose.yml:docker-compose.override.yml:${OVERLAY}"
add_env_key AUTH_PUBLIC_HOST "${AUTH_HOST}"
add_env_key TOOLS_PUBLIC_HOST "${TOOLS_HOST}"
add_env_key POZNOTE_PUBLIC_HOST "${POZNOTE_HOST}"
# Kredensial OIDC Poznote dibuat di sini supaya blueprint (yang menerapkannya
# sebagai client_id/client_secret provider OAuth2) dan container Poznote
# membaca nilai yang sama dari .env. add_env_key tidak menimpa nilai lama.
add_env_key POZNOTE_OIDC_CLIENT_ID "$(openssl rand -hex 20 | tr 'A-F' 'a-f')"
add_env_key POZNOTE_OIDC_CLIENT_SECRET "$(openssl rand -base64 48 | tr -d '\n' | tr '/+' '_-')"
chmod 600 .env

if [ "$MODE" = tunnel ] && [ ! -f cloudflared.env ]; then
  umask 077
  : > cloudflared.env
  chmod 600 cloudflared.env
  echo "Created empty ${APP_DIR}/cloudflared.env (add TUNNEL_TOKEN=... later)"
fi

# Start the private backends, including IT-Tools: it publishes no ports and
# is unreachable until Caddy/cloudflared start, so running it now is safe
# (fail closed behind no ingress). Public ingress (Caddy / cloudflared) is
# started manually after admin bootstrap, as printed in step 5/5.
docker compose pull
docker compose up -d server worker poznote it-tools

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
  log "Backends are up (no public ingress yet)"
  cat <<EOF

Next steps:
1) From the machine running your browser, open an SSH port-forward:
   ssh -N -L 9000:127.0.0.1:9000 -L 8040:127.0.0.1:8040 <user>@this-server
2) Create the Authentik admin account (choose a strong password) at:
   http://localhost:9000/if/flow/initial-setup/
3) Poznote (http://localhost:8040) still has default credentials
   admin_change_me / admin — change its admin username and password NOW,
   then verify the old credentials are rejected.

4) Caddy (and the tunnel connector) were NOT started by this script.
   IT-Tools is already running but unreachable: it publishes no port and
   only answers through Caddy behind the Authentik gate.

5) The demo blueprint (group demo-users, IT-Tools + Poznote providers,
   embedded outpost host) is mounted at /blueprints/demo.yaml. The worker
   auto-applies it within a minute of the admin setup completing — verify
   under Admin interface > Applications: group demo-users, apps IT-Tools
   and Poznote. Poznote OIDC settings must still be enabled in its UI:
   Settings > Admin Tools > OIDC / SSO (issuer https://${AUTH_HOST}/application/o/poznote/).

Only after BOTH admin accounts are secured, start public ingress from
${APP_DIR}:
EOF
  if [ "$MODE" = vps ]; then
    cat <<EOF
   docker compose up -d
   (starts Caddy on 80/443; certificates are issued by ACME on first request)
EOF
  else
    cat <<EOF
   docker compose --profile tunnel up -d cloudflared
   (the connector requires the real TUNNEL_TOKEN=... in ${APP_DIR}/cloudflared.env
    and the tunnel + hostname routes configured in the Cloudflare dashboard)
EOF
  fi
else
  echo "Not healthy after 5 minutes. Check logs with:"
  echo "  cd ${APP_DIR} && docker compose logs --tail=100"
  exit 1
fi
