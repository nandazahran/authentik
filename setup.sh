#!/usr/bin/env bash
# setup.sh - install the container engine and deploy Authentik
# Target: fresh Debian 12/13 or Ubuntu server (VPS with public IP, or
#         a local computer using Cloudflare Tunnel)
# Usage:  sudo ./setup.sh [--runtime docker] --vps <auth-host> <tools-host> <poznote-host> [--harden]
#         ./setup.sh --runtime podman --vps <auth-host> <tools-host> <poznote-host> [--harden]
#         ./setup.sh --runtime podman --tunnel <auth-host> <tools-host> <poznote-host> [--harden]
#   --runtime docker|podman (default: docker)
#   --vps    public deployment: Caddy with ACME certificates answers on
#            80/443 directly (needs a public IP + DNS records for the hosts)
#   --tunnel local deployment: ingress via Cloudflare Tunnel, no published
#            web port; the connector is activated later with the token
#   --harden also configure ufw, unattended-upgrades and fail2ban
#
# Docker runs as root at /opt/authentik. Podman runs rootless as the invoking
# non-root user at $HOME/.local/share/authentik: run the Podman branch from a
# normal SSH login, never under sudo.
#
# Requires (next to this script): Caddyfile (or Caddyfile.tunnel) and
# docker-compose.override.yml, plus docker-compose.vps.yml or
# docker-compose.tunnel.yml. The Podman branch additionally requires
# docker-compose.podman.yml, podman-compose.sh and authentik-podman.service.
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
APP_DIR=""
COMPOSE_URL="https://goauthentik.io/docker-compose.yml"
HTTP_PORT=9000
HARDEN=false
MODE=""
RUNTIME="docker"
RUNTIME_SET=false
HOSTS=()

COMPOSE_PROVIDER_VERSION="5.6.0"
COMPOSE_PROVIDER_SHA_X86_64="40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a"
COMPOSE_PROVIDER_SHA_AARCH64="733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Privileged operations: Docker runs as root already, Podman uses sudo.
run_priv() {
  if [ "$RUNTIME" = podman ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# Rootless Podman invocations: never inherit a rootful/remote engine config.
podman_user() {
  env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman "$@"
}

print_usage() {
  cat <<'EOF'
Usage: sudo ./setup.sh [--runtime docker] --vps|--tunnel <auth-host> <tools-host> <poznote-host> [--harden]
       ./setup.sh --runtime podman --vps|--tunnel <auth-host> <tools-host> <poznote-host> [--harden]

  --runtime docker|podman (default: docker)
  --vps     VPS with a public IP: Caddy + ACME answers on 80/443 directly
  --tunnel  Local computer: ingress via Cloudflare Tunnel (no published web port)
  --harden  also configure ufw, unattended-upgrades and fail2ban

Docker (default) runs as root at /opt/authentik:
  sudo ./setup.sh --vps auth.example.com tools.example.com poznote.example.com

Podman runs rootless as the invoking user at ~/.local/share/authentik,
from a normal SSH login (never under sudo):
  ./setup.sh --runtime podman --vps auth.example.com tools.example.com poznote.example.com
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vps|--tunnel)
      [ -n "$MODE" ] && die "Pick one mode: --vps or --tunnel"
      MODE="${1#--}"
      shift
      ;;
    --runtime)
      [ "$RUNTIME_SET" = true ] && die "Repeated --runtime: pass exactly one --runtime docker|podman"
      [ $# -ge 2 ] || die "Missing value for --runtime: pass --runtime docker|podman"
      case "$2" in
        docker|podman) RUNTIME="$2"; RUNTIME_SET=true; shift 2 ;;
        *) die "Unknown --runtime '$2': pass --runtime docker|podman" ;;
      esac
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

if [ "$RUNTIME" = docker ]; then
  APP_DIR="/opt/authentik"
else
  APP_DIR="$HOME/.local/share/authentik"
fi

# Subordinate ID ranges: at least one contiguous range of >= 65536 IDs for
# the login, with no overlap against other accounts' ranges in the same file.
check_subid_file() {
  file="$1"
  login="$2"
  uid="$3"
  [ -f "$file" ] || die "$file missing for account $login: ask the administrator to allocate at least one contiguous range of >= 65536 subordinate IDs to $login."
  ranges=$(awk -F: -v login="$login" -v uid="$uid" '
    ($1 == login || $1 == uid) && $3 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $2 ":" $3 }
  ' "$file")
  [ -n "$ranges" ] || die "$file has no range for account $login (name or uid $uid): ask the administrator to allocate at least one contiguous range of >= 65536 subordinate IDs to $login."
  ok=false
  for r in $ranges; do
    count="${r##*:}"
    if [ "$count" -ge 65536 ] 2>/dev/null; then ok=true; fi
  done
  [ "$ok" = true ] || die "$file has no range of >= 65536 IDs for account $login (found: $ranges): ask the administrator to allocate at least one contiguous range of >= 65536 subordinate IDs to $login."
  while read -r line; do
    [ -n "$line" ] || continue
    name="${line%%:*}"
    rest="${line#*:}"
    start="${rest%%:*}"
    count="${rest##*:}"
    [ "$name" = "$login" ] && continue
    [ "$name" = "$uid" ] && continue
    case "$start:$count" in *[!0-9:]*|"") continue;; esac
    for r in $ranges; do
      s="${r%%:*}"
      c="${r##*:}"
      if [ "$start" -lt $((s + c)) ] && [ "$s" -lt $((start + count)) ]; then
        die "$file range $start:$count for account $name overlaps $login range $s:$c: ask the administrator to allocate non-overlapping subordinate ranges."
      fi
    done
  done < "$file"
}

# User-owned standalone Compose provider (isolated path, verified bytes only).
install_compose_provider() {
  provider_dir="$HOME/.local/lib/authentik"
  provider="$provider_dir/docker-compose"
  arch=$(uname -m)
  case "$arch" in
    x86_64) want="$COMPOSE_PROVIDER_SHA_X86_64"; asset="docker-compose-linux-x86_64" ;;
    aarch64|arm64) want="$COMPOSE_PROVIDER_SHA_AARCH64"; asset="docker-compose-linux-aarch64" ;;
    *) die "Unsupported architecture $arch for Compose provider v$COMPOSE_PROVIDER_VERSION (need x86_64 or aarch64)." ;;
  esac
  mkdir -p "$provider_dir"
  if [ -x "$provider" ]; then
    have=$(sha256sum "$provider" | cut -d' ' -f1)
    if [ "$have" = "$want" ]; then
      echo "Compose provider v$COMPOSE_PROVIDER_VERSION already installed, keeping it."
      chmod 755 "$provider"
      return 0
    fi
    die "Conflicting binary at $provider (sha256 $have, want $want): inspect it, move it aside manually, then rerun."
  fi
  tmp=$(mktemp "$provider_dir/.docker-compose.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  curl -fsSL -o "$tmp" "https://github.com/docker/compose/releases/download/v${COMPOSE_PROVIDER_VERSION}/${asset}" \
    || die "Failed to download Compose provider v$COMPOSE_PROVIDER_VERSION for $arch."
  echo "$want  $tmp" | sha256sum -c - \
    || die "Compose provider checksum mismatch: refusing to install."
  chmod 755 "$tmp"
  mv "$tmp" "$provider"
  trap - RETURN
  chmod 755 "$provider"
  echo "Installed Compose provider v$COMPOSE_PROVIDER_VERSION at $provider."
}

podman_storage_prepare() {
  for d in data certs custom-templates; do
    src="$APP_DIR/$d"
    if [ -e "$src" ] && [ ! -d "$src" ]; then
      die "Bind source $src exists and is not a directory: move it aside explicitly."
    fi
    if [ -L "$src" ]; then
      die "Bind source $src is a symlink: replace it with a real directory explicitly."
    fi
  done
  fresh_data=false
  fresh_certs=false
  if [ ! -e "$APP_DIR/data" ]; then
    mkdir -p -m 0755 "$APP_DIR/data"
    echo "Created $APP_DIR/data (0755)."
    fresh_data=true
  fi
  if [ ! -e "$APP_DIR/certs" ]; then
    mkdir -p -m 0755 "$APP_DIR/certs"
    echo "Created $APP_DIR/certs (0755)."
    fresh_certs=true
  fi
  if [ ! -e "$APP_DIR/custom-templates" ]; then
    mkdir -p -m 0755 "$APP_DIR/custom-templates"
    echo "Created $APP_DIR/custom-templates (0755)."
  fi
  # Only directories created by THIS attempt get mapped ownership; existing
  # paths (even empty) are never initialized here.
  if [ "$fresh_data" = true ]; then
    podman_user unshare chown 1000:1000 "$APP_DIR/data" \
      || die "Failed to map ownership of fresh $APP_DIR/data to container UID 1000: check subordinate ranges and user namespaces."
    echo "Mapped fresh data ownership to container UID 1000."
  fi
  if [ "$fresh_certs" = true ]; then
    podman_user unshare chown 1000:1000 "$APP_DIR/certs" \
      || die "Failed to map ownership of fresh $APP_DIR/certs to container UID 1000: check subordinate ranges and user namespaces."
    echo "Mapped fresh certs ownership to container UID 1000."
  fi
}

podman_storage_check() {
  out=$("${APP_DIR}/podman-compose.sh" run --rm --no-deps --user authentik \
    --entrypoint /bin/sh worker -ec 'test -w /data && test -r /templates && test -w /certs' 2>&1) \
    || die "Rootless storage check failed: $out (check mapped ownership of $APP_DIR/data and $APP_DIR/certs for container UID 1000, readability of custom-templates)."
}

install_user_unit() {
  fresh_run="$1"
  src="$APP_DIR/authentik-podman.service"
  dst_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  dst="$dst_dir/authentik-podman.service"
  mkdir -p "$dst_dir"
  if [ -f "$dst" ]; then
    if cmp -s "$src" "$dst"; then
      echo "User unit already installed, keeping it."
    else
      echo "Existing unit $dst differs from $src: keeping operator version."
    fi
    return 0
  fi
  cp -p "$src" "$dst"
  chmod 644 "$dst"
  systemctl --user daemon-reload
  if [ "$fresh_run" = true ]; then
    systemctl --user enable --now authentik-podman.service
  else
    systemctl --user enable authentik-podman.service
    echo "Installed user unit for next boot (not started during this rerun)."
  fi
}

# 1. preflight
log "1/5 Preflight checks"

if [ "$RUNTIME" = docker ]; then
  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo ./setup.sh"
else
  [ "$(id -u)" -ne 0 ] || die "Run Podman as the deployment user, without sudo."
  [ -z "${SUDO_USER:-}" ] && [ -z "${SUDO_UID:-}" ] \
    || die "Run Podman as the deployment user, without sudo."
fi

. /etc/os-release
case "${ID}" in
  debian|ubuntu) ;;
  *) die "Unsupported OS: ${ID} (need Debian or Ubuntu)" ;;
esac
if [ "$RUNTIME" = podman ]; then
  ver="${VERSION_ID%%.*}"
  case "${ID}" in
    debian) [ "$ver" -ge 12 ] || die "Podman branch needs Debian >= 12 (found $PRETTY_NAME); Ubuntu 22.04 stays on Docker." ;;
    ubuntu) [ "$ver" -ge 24 ] || die "Podman branch needs Ubuntu >= 24.04 (found $PRETTY_NAME); Ubuntu 22.04 stays on Docker." ;;
  esac
fi
echo "OS: ${PRETTY_NAME} (runtime: ${RUNTIME})"

if [ "$RUNTIME" = podman ]; then
  for v in CONTAINERS_STORAGE_CONF CONTAINERS_CONF CONTAINERS_CONF_OVERRIDE PODMAN_USERNS; do
    [ -z "${!v:-}" ] || die "$v is set: unset it and rerun without container-storage overrides (default namespace mapping is required)."
  done
  expected_rtdir="/run/user/$(id -u)"
  [ "${XDG_RUNTIME_DIR:-}" = "$expected_rtdir" ] \
    || die "XDG_RUNTIME_DIR is '${XDG_RUNTIME_DIR:-unset}', want $expected_rtdir: log out, reconnect directly over SSH as this user, and rerun."
  [ -d "$XDG_RUNTIME_DIR" ] && [ "$(stat -c %u "$XDG_RUNTIME_DIR")" -eq "$(id -u)" ] \
    || die "Runtime directory $expected_rtdir missing or foreign: log out, reconnect directly over SSH as this user, and rerun."
  [ -d "$HOME" ] && [ -w "$HOME" ] \
    || die "Home $HOME missing or unwritable: a local usable home is required."
  fstype=$(findmnt -no FSTYPE -T "$HOME" 2>/dev/null || true)
  mntopts=$(findmnt -no OPTIONS -T "$HOME" 2>/dev/null || true)
  case ",$mntopts," in *,noexec,*) die "Home $HOME is mounted noexec: a local exec-capable home is required.";; esac
  case "$fstype" in
    nfs|nfs4|cifs|smbfs) die "Home $HOME is on $fstype: a local home filesystem is required; do not relocate storage automatically." ;;
  esac
  if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" != "cgroup2fs" ]; then
    die "cgroup v1 detected: rootless Podman needs cgroup v2."
  fi
  login_name="$(id -un)"
  login_uid="$(id -u)"
  check_subid_file /etc/subuid "$login_name" "$login_uid"
  check_subid_file /etc/subgid "$login_name" "$login_uid"
fi

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 1900 ] || die "Need at least ~2 GB RAM (found ${mem_mb} MB)"
echo "RAM: ${mem_mb} MB"
if [ "$mem_mb" -lt 2800 ]; then
  echo "Warning: ~3 GB RAM is recommended when running the demo apps."
fi

if [ "$RUNTIME" = podman ]; then
  disk_ref="$HOME"
  [ -d "$APP_DIR" ] && disk_ref="$APP_DIR"
  disk_gb=$(df --output=avail -BG "$disk_ref" | tail -1 | tr -dc '0-9')
  [ "$disk_gb" -ge 10 ] || die "Need at least 10 GB free disk under $disk_ref (found ${disk_gb} GB)"
  echo "Free disk under $disk_ref: ${disk_gb} GB"
else
  disk_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  [ "$disk_gb" -ge 10 ] || die "Need at least 10 GB free disk (found ${disk_gb} GB)"
  echo "Free disk: ${disk_gb} GB"
fi

[ -f "${SCRIPT_DIR}/docker-compose.override.yml" ] || die "docker-compose.override.yml not found next to setup.sh"
if [ "$MODE" = vps ]; then
  [ -f "${SCRIPT_DIR}/Caddyfile" ] || die "Caddyfile not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/docker-compose.vps.yml" ] || die "docker-compose.vps.yml not found next to setup.sh"
else
  [ -f "${SCRIPT_DIR}/Caddyfile.tunnel" ] || die "Caddyfile.tunnel not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/docker-compose.tunnel.yml" ] || die "docker-compose.tunnel.yml not found next to setup.sh"
fi
if [ "$RUNTIME" = podman ]; then
  [ -f "${SCRIPT_DIR}/docker-compose.podman.yml" ] || die "docker-compose.podman.yml not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/podman-compose.sh" ] || die "podman-compose.sh not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/authentik-podman.service" ] || die "authentik-podman.service not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/docker-compose.blueprint.yml" ] || die "docker-compose.blueprint.yml not found next to setup.sh"
  [ -f "${SCRIPT_DIR}/blueprint.yaml" ] || die "blueprint.yaml not found next to setup.sh"
fi

# Runtime ownership gate: before packages or file edits.
if [ -f "${APP_DIR}/.container-runtime" ]; then
  # Ownership first: a foreign 0600 marker is unreadable, so reading it before
  # the owner check would die under set -e with no actionable message.
  if [ "$RUNTIME" = podman ]; then
    [ "$(stat -c %u "${APP_DIR}/.container-runtime")" -eq "$(id -u)" ] \
      || die "Marker ${APP_DIR}/.container-runtime is not owned by $(id -un): refusing to adopt another account's storage."
  fi
  marker_content=$(cat "${APP_DIR}/.container-runtime")
  if [ "$RUNTIME" = docker ]; then
    [ "$marker_content" = "docker" ] \
      || die "Runtime mismatch: deployment storage belongs to another engine or privilege mode; migrate data explicitly."
  else
    [ "$marker_content" = "podman-rootless" ] \
      || die "Runtime mismatch: deployment storage belongs to another engine or privilege mode; migrate data explicitly."
  fi
else
  if [ "$RUNTIME" = podman ]; then
    if [ -f "${APP_DIR}/.env" ] || [ -f "${APP_DIR}/docker-compose.yml" ]; then
      die "Existing ${APP_DIR} has config but no podman-rootless marker: refusing to adopt ambiguous storage; migrate data explicitly."
    fi
  fi
fi

FIRST_RUN=true
if [ -f "${APP_DIR}/docker-compose.yml" ]; then
  FIRST_RUN=false
fi

# Only check ports on a first run (later runs would see our own containers)
if [ "$FIRST_RUN" = true ]; then
  ports_to_check=("${HTTP_PORT}")
  [ "$MODE" = vps ] && ports_to_check+=(80 443)
  for p in "${ports_to_check[@]}"; do
    if ss -ltn | grep -q ":${p} "; then
      die "Port ${p} is already in use"
    fi
  done
fi

# 2. install engine
if [ "$RUNTIME" = docker ]; then
  log "2/5 Installing Docker from the official apt repository"

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker and Compose plugin already installed, skipping."
  else
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  docker --version
  docker compose version

  # Both overlays use !override (server/poznote ports) and the tunnel overlay
  # also !reset (caddy.ports), which needs Compose >= 2.24.4. Checked AFTER
  # installation so fresh hosts pass too.
  compose_version=$(docker compose version --short 2>/dev/null | tr -dc '0-9.' || true)
  lowest=$(printf '%s\n2.24.4\n' "$compose_version" | sort -V | head -1)
  [ "$lowest" = "2.24.4" ] \
    || die "docker-compose.vps.yml/docker-compose.tunnel.yml need Compose >= 2.24.4 (found: ${compose_version:-unknown})"
else
  log "2/5 Installing rootless Podman prerequisites (distro packages)"

  run_priv apt-get update || die "apt-get update failed (sudo required for host packages)."
  if ! run_priv apt-get install -y podman ca-certificates curl openssl uidmap \
      slirp4netns fuse-overlayfs dbus-user-session netavark aardvark-dns; then
    die "Podman package install failed; on Ubuntu enable 'universe' first (sudo add-apt-repository universe), then rerun."
  fi
  command -v podman >/dev/null 2>&1 || die "podman not found after installation."
  for bin in newuidmap newgidmap slirp4netns fuse-overlayfs; do
    command -v "$bin" >/dev/null 2>&1 \
      || die "Missing prerequisite $bin after package install: install it as administrator, then rerun."
  done
  # Capture first: `podman --version | grep | head -1` under set -euo pipefail
  # dies silently (grep no-match rc=1, or SIGPIPE rc=141 from head).
  podman_out=$(podman_user --version 2>&1) || die "podman --version failed: ${podman_out:-<empty>}"
  podman_ver=$(printf '%s\n' "$podman_out" | grep -oE -m1 '[0-9]+\.[0-9]+(\.[0-9]+)?') || true
  [ -n "$podman_ver" ] || die "Could not parse a Podman version from: $podman_out"
  lowest=$(printf '%s\n4.3.0\n' "$podman_ver" | sort -V | head -1)
  [ "$lowest" = "4.3.0" ] \
    || die "Podman branch needs Podman >= 4.3.0 (found: ${podman_ver:-unknown})."
  echo "Podman: $(podman_user --version)"

  systemctl --user show-environment >/dev/null 2>&1 \
    || die "Log out, reconnect directly over SSH as this user, and rerun."
  unshare_out=$(podman_user unshare true 2>&1) \
    || {
      audit=$(dmesg 2>/dev/null | grep -Ei 'apparmor.*(denied|userns_create)' | tail -5 || true)
      if [ -n "$audit" ]; then
        printf '%s\n' "$audit" >&2
        die "Rootless namespaces blocked (AppArmor userns_create denial above): ask the administrator for a narrowly scoped AppArmor policy from distro Podman/AppArmor packages, then retry after a fresh direct login. Never disable AppArmor/seccomp/userns globally."
      fi
      die "Rootless namespaces blocked: $unshare_out"
    }
  rootless=$(podman_user info --format '{{.Host.Security.Rootless}}' 2>&1) \
    || die "podman info failed: $rootless"
  [ "$rootless" = "true" ] || die "Podman is not rootless (Host.Security.Rootless=$rootless)."
  # Cgroup v2 template name differs across Podman versions (Host.CgroupVersion
  # on 4.x/5.x; verify via JSON so 6.x is accepted too).
  cgroup_json=$(podman_user info --format '{{json .Host}}' 2>&1) \
    || die "podman info failed: $cgroup_json"
  case "$cgroup_json" in
    *'"cgroupVersion":"v2"'*) echo "Cgroup: v2" ;;
    *) die "Podman cgroup is not v2 (Host JSON lacks cgroupVersion v2)." ;;
  esac

  backend=$(podman_user info --format '{{.Host.NetworkBackend}}' 2>&1) \
    || die "podman info failed: $backend"
  case "$backend" in
    netavark) echo "Network backend: netavark" ;;
    cni)
      echo "Network backend: cni (Debian 12 legacy)"
      run_priv apt-get install -y containernetworking-plugins golang-github-containernetworking-plugin-dnsname \
        || die "CNI plugin install failed."
      ;;
    *) die "Unknown Podman network backend '$backend': keep netavark; never reset existing networks." ;;
  esac

  install_compose_provider

  systemctl --user enable --now podman.socket \
    || die "Failed to start user podman.socket."
  run_priv loginctl enable-linger "$(id -un)" \
    || die "Failed to enable linger for $(id -un)."
  [ "$(loginctl show-user "$(id -un)" -p Linger --value)" = "yes" ] \
    || die "Linger not enabled for $(id -un)."
  ping=$(curl --fail --silent --show-error --unix-socket "$XDG_RUNTIME_DIR/podman/podman.sock" http://localhost/_ping 2>&1) \
    || die "User Podman socket _ping failed: $ping"
  [ "$ping" = "OK" ] || die "User Podman socket _ping returned '$ping', want OK."
  systemctl --user is-active podman.socket >/dev/null 2>&1 \
    || die "podman.socket is not active."

  if [ "$MODE" = vps ]; then
    current_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start)
    if [ "$current_start" -le 80 ] 2>/dev/null; then
      echo "Unprivileged port start is $current_start: existing policy suffices."
    else
      sysctl_file="/etc/sysctl.d/90-authentik-rootless-ports.conf"
      want_line="net.ipv4.ip_unprivileged_port_start = 80"
      if [ -f "$sysctl_file" ]; then
        if [ "$(cat "$sysctl_file")" = "$want_line" ]; then
          echo "Reusing identical $sysctl_file."
        else
          die "Conflicting $sysctl_file exists with different content: resolve it explicitly, refusing to overwrite."
        fi
      else
        printf '%s\n' "$want_line" | run_priv tee "$sysctl_file" >/dev/null
        run_priv chmod 0644 "$sysctl_file"
        echo "Wrote $sysctl_file."
      fi
      run_priv sysctl -w net.ipv4.ip_unprivileged_port_start=80
      current_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start)
      [ "$current_start" -le 80 ] \
        || die "Unprivileged port start still $current_start after sysctl: another host policy overrides it; refusing to rewrite unrelated sysctl files."
      echo "Note: every local user can now bind ports >= 80."
    fi
  fi
fi

# 3. hardening
log "3/5 Base hardening"

if [ "$HARDEN" = true ]; then
  # Fresh hosts (and Docker-skipped runs) may not have run apt-get update yet,
  # so the package index can be empty/stale here.
  run_priv apt-get update
  run_priv apt-get install -y ufw unattended-upgrades fail2ban

  # allow SSH BEFORE enabling the firewall so we don't lock ourselves out
  run_priv ufw default deny incoming
  run_priv ufw default allow outgoing
  run_priv ufw allow OpenSSH || run_priv ufw allow 22/tcp
  if [ "$MODE" = vps ]; then
    # Caddy is the public entry point (ACME needs 80 + 443 inbound)
    run_priv ufw allow 80/tcp
    run_priv ufw allow 443/tcp
  else
    # Tunnel mode: no inbound web ports. cloudflared connects OUTBOUND to
    # Cloudflare on TCP/UDP 7844, already covered by 'default allow
    # outgoing' above. No inbound 7844 rule is needed or wanted.
    :
  fi
  run_priv ufw --force enable

  run_priv dpkg-reconfigure -f noninteractive unattended-upgrades || true
  run_priv systemctl enable --now fail2ban
  echo "Note: Docker-published ports can bypass ufw. Verify with nmap from another machine."
else
  echo "Skipped (run with --harden to enable ufw, unattended-upgrades, fail2ban)."
fi

# 4. deploy authentik
log "4/5 Deploying Authentik (runtime: ${RUNTIME})"

NEW_DIR=false
[ -d "$APP_DIR" ] || NEW_DIR=true
mkdir -p "${APP_DIR}"
if [ "$NEW_DIR" = true ]; then
  chmod 700 "${APP_DIR}"
fi
if [ ! -f "${APP_DIR}/.container-runtime" ]; then
  if [ "$RUNTIME" = docker ]; then
    if [ "$FIRST_RUN" = true ]; then
      echo "docker" > "${APP_DIR}/.container-runtime"
      chmod 600 "${APP_DIR}/.container-runtime"
    fi
  else
    echo "podman-rootless" > "${APP_DIR}/.container-runtime"
    chmod 600 "${APP_DIR}/.container-runtime"
  fi
fi
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

# Resolve a variable the same way compose does for this deployment. The guard
# below must match the operator's real database: ${APP_DIR}/.env may set
# PG_USER/PG_DB to custom values, and silently dumping a different database
# would still produce a non-empty file that passes a "did it work?" check.
# Operators' exported values still win, matching add_env_key's precedence.
env_file_value() {
  key="$1"
  grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r'
}

AUTHENTIK_TAG_PIN="${AUTHENTIK_TAG_PIN:-2026.8.4}"
export AUTHENTIK_TAG_PIN
add_env_key AUTHENTIK_TAG "${AUTHENTIK_TAG_PIN}"

PG_USER="${PG_USER:-$(env_file_value PG_USER)}"
PG_DB="${PG_DB:-$(env_file_value PG_DB)}"
PG_USER="${PG_USER:-authentik}"
PG_DB="${PG_DB:-authentik}"
export PG_USER PG_DB

if [ "$MODE" = vps ]; then
  OVERLAY="docker-compose.vps.yml"
  CADDY_FILE="Caddyfile"
else
  OVERLAY="docker-compose.tunnel.yml"
  CADDY_FILE="Caddyfile.tunnel"
fi

COPY_LIST="docker-compose.override.yml ${OVERLAY} ${CADDY_FILE} docker-compose.blueprint.yml blueprint.yaml"
if [ "$RUNTIME" = podman ]; then
  COPY_LIST="$COPY_LIST docker-compose.podman.yml podman-compose.sh authentik-podman.service"
fi
for f in $COPY_LIST; do
  if [ ! -f "$f" ]; then
    cp -p "${SCRIPT_DIR}/${f}" "$f"
    if [ "$f" = "podman-compose.sh" ]; then
      chmod +x "$f"
    fi
    echo "Copied ${f}"
  else
    echo "${f} already present, keeping it."
  fi
done

if [ "$RUNTIME" = podman ]; then
  chmod +x "${APP_DIR}/podman-compose.sh"
fi

# A stale/foreign COMPOSE_FILE must not silently win: if it does not select
# this mode's overlay, the base file publishes 9000/9443 on all interfaces.
current_compose_file=$(grep -E '^COMPOSE_FILE=' .env | tail -1 | cut -d= -f2- || true)
if [ -n "$current_compose_file" ] \
  && ! printf '%s' "$current_compose_file" | tr ':' '\n' | grep -qx "${OVERLAY}"; then
  die "COMPOSE_FILE in .env is '${current_compose_file}' and does not include ${OVERLAY}. Edit ${APP_DIR}/.env and set COMPOSE_FILE to select the intended overlay (docker-compose.yml:docker-compose.override.yml:${OVERLAY}), then re-run."
fi
if [ -n "$current_compose_file" ]; then
  if [ "$RUNTIME" = docker ]; then
    if printf '%s' "$current_compose_file" | tr ':' '\n' | grep -qx "docker-compose.podman.yml"; then
      die "COMPOSE_FILE in .env selects docker-compose.podman.yml but --runtime docker was requested: runtime mismatch; migrate data explicitly."
    fi
  else
    if ! printf '%s' "$current_compose_file" | tr ':' '\n' | grep -qx "docker-compose.podman.yml"; then
      die "COMPOSE_FILE in .env is '${current_compose_file}' and does not include docker-compose.podman.yml. Edit ${APP_DIR}/.env to use the Podman file order, then re-run."
    fi
    podman_pos=$(printf '%s' "$current_compose_file" | tr ':' '\n' | grep -n -x "docker-compose.podman.yml" | cut -d: -f1)
    overlay_pos=$(printf '%s' "$current_compose_file" | tr ':' '\n' | grep -n -x "${OVERLAY}" | cut -d: -f1)
    [ "$podman_pos" -gt "$overlay_pos" ] \
      || die "COMPOSE_FILE in .env lists docker-compose.podman.yml before ${OVERLAY}: storage replacement must come after the mode overlay."
    if printf '%s' "$current_compose_file" | tr ':' '\n' | grep -qx "docker-compose.blueprint.yml"; then
      last=$(printf '%s' "$current_compose_file" | tr ':' '\n' | tail -1)
      [ "$last" = "docker-compose.blueprint.yml" ] \
        || die "COMPOSE_FILE in .env must list docker-compose.blueprint.yml last so its worker mount survives Podman storage replacement."
    fi
  fi
fi

add_env_key AUTH_PUBLIC_HOST "${AUTH_HOST}"
add_env_key TOOLS_PUBLIC_HOST "${TOOLS_HOST}"
add_env_key POZNOTE_PUBLIC_HOST "${POZNOTE_HOST}"
# Kredensial OIDC Poznote dibuat di sini supaya blueprint (yang menerapkannya
# sebagai client_id/client_secret provider OAuth2) dan container Poznote
# membaca nilai yang sama dari .env. add_env_key tidak menimpa nilai lama.
add_env_key POZNOTE_OIDC_CLIENT_ID "$(openssl rand -hex 20 | tr 'A-F' 'a-f')"
add_env_key POZNOTE_OIDC_CLIENT_SECRET "$(openssl rand -base64 48 | tr -d '\n' | tr '/+' '_-')"

# COMPOSE_FILE: mode overlay + blueprint overlay (opt-in lewat setup.sh;
# deployment manual tanpa setup.sh tidak usah menambahkannya). Podman inserts
# docker-compose.podman.yml before the blueprint overlay so the blueprint
# worker mount survives the volume replacement. Required entries are reordered
# into their canonical slots — base:override:mode:<custom entries>:podman:
# blueprint — so precedence is never inverted by a plain append, a misplaced
# required entry moves instead of duplicating, blueprint stays strictly last,
# and custom entries keep their relative order.
compose_order() {
  current="$1" runtime="$2" overlay="$3"
  result_base=""
  result_override=""
  result_overlay=""
  result_podman=""
  result_blueprint=""
  customs=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      docker-compose.yml)
        [ -z "$result_base" ] && result_base="$entry"
        ;;
      docker-compose.override.yml)
        [ -z "$result_override" ] && result_override="$entry"
        ;;
      docker-compose.podman.yml)
        [ -z "$result_podman" ] && result_podman="$entry"
        ;;
      docker-compose.blueprint.yml)
        [ -z "$result_blueprint" ] && result_blueprint="$entry"
        ;;
      "$overlay")
        [ -z "$result_overlay" ] && result_overlay="$entry"
        ;;
      *)
        case ":$customs:" in
          *":$entry:"*) ;;
          *) customs="${customs:+$customs:}$entry" ;;
        esac
        ;;
    esac
  done <<EOF
$(printf '%s' "$current" | tr ':' '\n')
EOF
  # Reorder only guarantees placement; required entries that are entirely
  # absent must still be added at their canonical slot.
  [ -n "$result_base" ] || result_base="docker-compose.yml"
  [ -n "$result_override" ] || result_override="docker-compose.override.yml"
  [ -n "$result_overlay" ] || result_overlay="$overlay"
  if [ "$runtime" = podman ]; then
    [ -n "$result_podman" ] || result_podman="docker-compose.podman.yml"
    # Blueprint last: its worker mount must survive Podman volume replacement.
    [ -n "$result_blueprint" ] || result_blueprint="docker-compose.blueprint.yml"
  else
    [ -n "$result_blueprint" ] || result_blueprint="docker-compose.blueprint.yml"
  fi
  out=""
  add() { [ -n "$1" ] || return 0; out="${out:+$out:}$1"; }
  add "$result_base"
  add "$result_override"
  add "$result_overlay"
  add "$customs"
  if [ "$runtime" = podman ]; then
    add "$result_podman"
    add "$result_blueprint"
  else
    add "$result_blueprint"
  fi
  printf '%s' "$out"
}

if ! grep -q '^COMPOSE_FILE=' .env; then
  if [ "$RUNTIME" = docker ]; then
    echo "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:${OVERLAY}:docker-compose.blueprint.yml" >> .env
  else
    echo "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:${OVERLAY}:docker-compose.podman.yml:docker-compose.blueprint.yml" >> .env
  fi
  echo "Added COMPOSE_FILE to .env"
else
  current=$(grep -E '^COMPOSE_FILE=' .env | tail -1 | cut -d= -f2- || true)
  updated=$(compose_order "$current" "$RUNTIME" "$OVERLAY")
  if [ "$updated" != "$current" ]; then
    sed -i "s|^COMPOSE_FILE=.*|COMPOSE_FILE=${updated}|" .env
    echo "Updated COMPOSE_FILE to ${updated}"
  else
    echo "COMPOSE_FILE already complete, custom entries preserved."
  fi
fi
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
if [ "$RUNTIME" = docker ]; then
  docker compose config --quiet
  # An image upgrade can apply Django migrations; if it fails midway the
  # deployment boots into InconsistentMigrationHistory and crash-loops.
  # Snapshot the database first so the previous state is recoverable.
  if [ "$FIRST_RUN" = false ] && [ "${FORCE_UPGRADE:-0}" != 1 ]; then
    if docker compose ps --status running --services 2>/dev/null | grep -qx postgresql; then
      stamp=$(date +%Y%m%d-%H%M%S)
      backup="${APP_DIR}/authentik-pre-upgrade-${stamp}.dump"
      # --schema-only dump first proves we can read the RIGHT database: a dump of
      # the wrong DB still produces a non-empty file, which would silently pass a
      # naive "-s" check and leave the operator with a useless backup.
      if ! docker compose exec -T postgresql pg_dump -U "${PG_USER}" -Fc "${PG_DB}" \
        > "${backup}" 2>/dev/null || [ ! -s "${backup}" ]; then
        rm -f "${backup}"
        die "Pre-upgrade database backup failed (PG_USER=${PG_USER} PG_DB=${PG_DB}); refusing to pull new images.
Restore a broken upgrade from the previous dump: see README.
Skip this safety net deliberately with FORCE_UPGRADE=1."
      fi
      # The deployment must contain authentik's own tables; anything else means
      # the credentials pointed somewhere else and the dump is worthless.
      if ! docker compose exec -T postgresql psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
        "select 1 from information_schema.tables where table_name='django_migrations'" \
        2>/dev/null | grep -q 1; then
        rm -f "${backup}"
        die "Backup of PG_DB=${PG_DB} contains no authentik tables (django_migrations absent):
this is not the deployment database, so the snapshot is worthless. Check PG_USER/PG_DB in
${APP_DIR}/.env. Refusing to pull new images.
Skip this safety net deliberately with FORCE_UPGRADE=1."
      fi
      chmod 600 "${backup}"
      log "Database backed up to ${backup} (PG_USER=${PG_USER} PG_DB=${PG_DB})"
    else
      die "Refusing to pull images: postgresql is not running, so the database cannot be backed up first.
Start the stack (docker compose up -d) or, if the database is already broken, restore from the newest
${APP_DIR}/authentik-pre-upgrade-*.dump. Skip this safety net deliberately with FORCE_UPGRADE=1."
    fi
  fi
  docker compose pull
  docker compose up -d server worker poznote it-tools
else
  "${APP_DIR}/podman-compose.sh" config --quiet
  # Same crash-loop risk as the Docker path: an image upgrade runs Django
  # migrations that can fail midway. Snapshot the database first.
  if [ "$FIRST_RUN" = false ] && [ "${FORCE_UPGRADE:-0}" != 1 ] \
    && "${APP_DIR}/podman-compose.sh" ps --status running --services 2>/dev/null | grep -qx postgresql; then
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="${APP_DIR}/authentik-pre-upgrade-${stamp}.dump"
    # Same two-stage check as the Docker path: non-empty, and actually the
    # authentik database (a dump of the wrong DB also looks non-empty).
    if ! "${APP_DIR}/podman-compose.sh" exec -T postgresql pg_dump -U "${PG_USER}" -Fc "${PG_DB}" \
      > "${backup}" 2>/dev/null || [ ! -s "${backup}" ]; then
      rm -f "${backup}"
      die "Pre-upgrade database backup failed (PG_USER=${PG_USER} PG_DB=${PG_DB}); refusing to pull new images.
Skip this safety net deliberately with FORCE_UPGRADE=1."
    fi
    if ! "${APP_DIR}/podman-compose.sh" exec -T postgresql psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
      "select 1 from information_schema.tables where table_name='django_migrations'" \
      2>/dev/null | grep -q 1; then
      rm -f "${backup}"
      die "Backup of PG_DB=${PG_DB} contains no authentik tables (django_migrations absent):
this is not the deployment database, so the snapshot is worthless. Check PG_USER/PG_DB in
${APP_DIR}/.env. Refusing to pull new images.
Skip this safety net deliberately with FORCE_UPGRADE=1."
    fi
    chmod 600 "${backup}"
    log "Database backed up to ${backup} (PG_USER=${PG_USER} PG_DB=${PG_DB})"
  fi
  "${APP_DIR}/podman-compose.sh" pull
  podman_storage_prepare
  podman_storage_check
  "${APP_DIR}/podman-compose.sh" up -d server worker poznote it-tools
fi

# 5. verify
log "5/5 Waiting for Authentik to become healthy"

ready=false
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${HTTP_PORT}/-/health/live/" || true)
  if [[ "$code" =~ ^2 ]]; then ready=true; break; fi
  printf '.'
  sleep 5
done
echo

# A crash-looping server can serve a single 2xx between respawns, so health
# alone is not proof. Require the restart count to stay flat across a window:
# 2026.8's Rust supervisor reports "the server has exited unexpectedly" and
# restarts the container instead of failing, which a liveness probe alone
# hides. Failing here beats leaving a half-migrated stack running.
if [ "$ready" = true ] && [ "$RUNTIME" = docker ] && [ "${FORCE_UPGRADE:-0}" != 1 ]; then
  if docker inspect authentik-server-1 >/dev/null 2>&1; then
    a=$(docker inspect -f '{{.RestartCount}}' authentik-server-1 2>/dev/null || echo 0)
    sleep 45
    b=$(docker inspect -f '{{.RestartCount}}' authentik-server-1 2>/dev/null || echo 0)
    if [ "$a" != "$b" ]; then
      die "Authentik server restarted ${a} -> ${b} during the stability window: the container is crash-looping.
A fresh boot failure here is usually a migration/schema problem, not the network. Do NOT start
public ingress on this. Inspect with:
  cd ${APP_DIR} && docker compose logs --tail=100 server | grep -iE 'Traceback|inconsistent|exited unexpectedly'
Restore from the newest ${APP_DIR}/authentik-pre-upgrade-*.dump if this followed an upgrade.
Skip this safety net deliberately with FORCE_UPGRADE=1."
    fi
    log "Stability window passed (restart count ${a} unchanged)"
  fi
fi

if [ "$ready" = true ]; then
  if [ "$RUNTIME" = podman ]; then
    install_user_unit "$FIRST_RUN"
  fi
  log "Backends are up (no public ingress yet)"
  cat <<EOF

Next steps:
1) From the machine running your browser, open an SSH port-forward:
   ssh -N -L 9000:127.0.0.1:9000 -L 8040:127.0.0.1:8040 <user>@this-server
2) Create the Authentik admin account (choose a strong password) at:
   http://localhost:9000/if/flow/initial-setup/
3) Poznote (http://localhost:8040) still has default credentials
   admin_change_me / admin: change its admin username and password NOW,
   then verify the old credentials are rejected.

4) Caddy (and the tunnel connector) were NOT started by this script.
   IT-Tools is already running but unreachable: it publishes no port and
   only answers through Caddy behind the Authentik gate.

5) The demo blueprint (group demo-users, IT-Tools + Poznote providers,
   embedded outpost host) is mounted at /blueprints/custom/demo.yaml. The worker
   auto-applies it within a minute of the admin setup completing, verify
   under Admin interface > Applications: group demo-users, apps IT-Tools
   and Poznote. Poznote OIDC settings must still be enabled in its UI:
   Settings > Admin Tools > OIDC / SSO (issuer https://${AUTH_HOST}/application/o/poznote/).

Only after BOTH admin accounts are secured, start public ingress from
${APP_DIR}:
EOF
  if [ "$MODE" = vps ]; then
    if [ "$RUNTIME" = docker ]; then
      cat <<EOF
   docker compose up -d
   (starts Caddy on 80/443; certificates are issued by ACME on first request)
EOF
    else
      cat <<EOF
   ${APP_DIR}/podman-compose.sh up -d
   (starts Caddy on 80/443 via the accepted unprivileged-port sysctl; certificates are issued by ACME on first request)
EOF
    fi
  else
    if [ "$RUNTIME" = docker ]; then
      cat <<EOF
   docker compose --profile tunnel up -d cloudflared
   (the connector requires the real TUNNEL_TOKEN=... in ${APP_DIR}/cloudflared.env
    and the tunnel + hostname routes configured in the Cloudflare dashboard)
EOF
    else
      cat <<EOF
   ${APP_DIR}/podman-compose.sh --profile tunnel up -d cloudflared
   (the connector requires the real TUNNEL_TOKEN=... in ${APP_DIR}/cloudflared.env
    and the tunnel + hostname routes configured in the Cloudflare dashboard)
EOF
    fi
  fi
else
  echo "Not healthy after 5 minutes. Check logs with:"
  if [ "$RUNTIME" = docker ]; then
    echo "  cd ${APP_DIR} && docker compose logs --tail=100"
  else
    echo "  cd ${APP_DIR} && ./podman-compose.sh logs --tail=100"
  fi
  exit 1
fi
