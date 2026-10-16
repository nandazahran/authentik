#!/usr/bin/env bash
# podman-compose.sh - deterministic rootless Compose entry point.
# Shared by manual and automated deployment. No sudo, no root.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run Podman as the deployment user, without sudo."

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HELPER_DIR"

UID_NOW="$(id -u)"
[ "$(stat -c %u "$HELPER_DIR")" -eq "$UID_NOW" ] \
  || die "Deployment directory $HELPER_DIR is not owned by uid $UID_NOW."

MARKER="$HELPER_DIR/.container-runtime"
[ -f "$MARKER" ] || die "Missing $MARKER: expected marker with contents 'podman-rootless'."
[ "$(stat -c %u "$MARKER")" -eq "$UID_NOW" ] \
  || die "Marker $MARKER is not owned by uid $UID_NOW."
grep -qx 'podman-rootless' "$MARKER" \
  || die "Runtime mismatch: deployment storage belongs to another engine or privilege mode; migrate data explicitly."

for arg in "$@"; do
  case "$arg" in
    -p|--project-name|--project-name=*|-p*)
      die "Project name override rejected: boot unit targets project 'authentik'."
      ;;
  esac
done

for bin in newuidmap newgidmap slirp4netns fuse-overlayfs; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "Missing prerequisite $bin: install distro packages as administrator, then retry."
done

[ -n "${XDG_RUNTIME_DIR:-}" ] || die "XDG_RUNTIME_DIR is unset: log out, reconnect directly over SSH as this user, and rerun."
[ -d "$XDG_RUNTIME_DIR" ] || die "Runtime directory $XDG_RUNTIME_DIR missing: log out, reconnect directly over SSH as this user, and rerun."
[ "$(stat -c %u "$XDG_RUNTIME_DIR")" -eq "$UID_NOW" ] \
  || die "Runtime directory $XDG_RUNTIME_DIR is not owned by uid $UID_NOW."
systemctl --user show-environment >/dev/null 2>&1 \
  || die "User manager unavailable: log out, reconnect directly over SSH as this user, and rerun."

SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"
[ "$SOCK" != "/run/podman/podman.sock" ] \
  || die "Refusing rootful Podman socket $SOCK."
[ -S "$SOCK" ] || die "User Podman socket $SOCK missing: run 'systemctl --user enable --now podman.socket' and retry."
[ "$(stat -c %u "$SOCK")" -eq "$UID_NOW" ] \
  || die "User Podman socket $SOCK is not owned by uid $UID_NOW."

PROVIDER="$HOME/.local/lib/authentik/docker-compose"
[ -x "$PROVIDER" ] \
  || die "Compose provider $PROVIDER missing: run setup.sh --runtime podman to install verified Compose v5.6.0."

# shellcheck disable=SC2086
exec env -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
  -u DOCKER_CERT_PATH -u DOCKER_API_VERSION -u CONTAINER_HOST \
  -u CONTAINER_CONNECTION \
  DOCKER_HOST="unix://$SOCK" \
  "$PROVIDER" --project-directory "$HELPER_DIR" -p authentik "$@"
