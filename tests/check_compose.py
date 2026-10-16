#!/usr/bin/env python3
"""Compose model regression check: Docker/Podman x VPS/tunnel x blueprint off/on.

Usage:
  python3 tests/check_compose.py --compose <compose-bin> --base <upstream-compose.yml>

Builds an isolated fixture (dummy secrets/hosts, empty connector env, repo
overlays/config/blueprint) and runs `config --format json` with the exact
COMPOSE_FILE order per runtime/mode, tunnel profile enabled when inspecting
the connector. No engine connection needed. Asserts:

- exact port isolation (server 127.0.0.1:9000 only; poznote 127.0.0.1:8040
  only; VPS Caddy 80/443; tunnel Caddy no ports)
- cloudflared profile declaration preserved
- Podman worker has exactly the data/certs/templates binds, no socket mount
- Docker worker keeps its model unchanged (upstream socket + binds)
- blueprint read-only mount present only when opted in, surviving Podman
  storage replacement
- short-name images qualified with docker.io registry in repo overlays
- missing public-host variables fail interpolation
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DUMMY_ENV = {
    "PG_PASS": "dummy-pg-pass",
    "AUTHENTIK_SECRET_KEY": "dummy-secret-key-0123456789abcdef",
    "AUTHENTIK_ERROR_REPORTING__ENABLED": "false",
    "AUTH_PUBLIC_HOST": "auth.example.com",
    "TOOLS_PUBLIC_HOST": "tools.example.com",
    "POZNOTE_PUBLIC_HOST": "poznote.example.com",
    "POZNOTE_OIDC_CLIENT_ID": "dummy-client-id",
    "POZNOTE_OIDC_CLIENT_SECRET": "dummy-client-secret",
}

BASE_FILES = [
    "docker-compose.override.yml",
    "docker-compose.vps.yml",
    "docker-compose.tunnel.yml",
    "docker-compose.podman.yml",
    "docker-compose.blueprint.yml",
    "Caddyfile",
    "Caddyfile.tunnel",
    "blueprint.yaml",
]


def scrub_env():
    env = dict(os.environ)
    for var in (
        "COMPOSE_FILE",
        "COMPOSE_PROFILES",
        "COMPOSE_PROJECT_NAME",
        "DOCKER_CONTEXT",
        "DOCKER_TLS",
        "DOCKER_TLS_VERIFY",
        "DOCKER_CERT_PATH",
        "DOCKER_API_VERSION",
        "CONTAINER_HOST",
        "CONTAINER_CONNECTION",
    ):
        env.pop(var, None)
    return env


def ports_of(service):
    out = []
    for p in service.get("ports") or []:
        out.append(
            (
                str(p.get("published") or ""),
                str(p.get("target") or ""),
                str(p.get("host_ip") or ""),
            )
        )
    return sorted(out)


def volume_targets(service):
    # Bind sources resolve to absolute host paths in canonical config; key on
    # target so fixtures stay hermetic.
    return sorted(v.get("target") or "" for v in service.get("volumes") or [])


def run_config(compose_bin, project_dir, env_file, files, profile=None):
    cmd = [
        compose_bin,
        "--project-directory",
        str(project_dir),
        "--env-file",
        str(env_file),
        "-p",
        "authentik",
    ]
    if profile:
        cmd += ["--profile", profile]
    cmd += ["-f", str(files[0])]
    for f in files[1:]:
        cmd += ["-f", str(f)]
    cmd += ["config", "--format", "json"]
    env = scrub_env()
    env["COMPOSE_FILE"] = ":".join(f.name for f in files)
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=project_dir)
    return proc


FAILURES = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        FAILURES.append(label)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compose", required=True)
    ap.add_argument("--base", required=True)
    args = ap.parse_args()

    compose_bin = args.compose
    base = Path(args.base)
    if not base.is_file():
        print(f"FAIL base compose file missing: {base}")
        return 1
    if not (shutil.which(compose_bin) or Path(compose_bin).is_file()):
        print(f"FAIL compose binary missing: {compose_bin}")
        return 1

    with tempfile.TemporaryDirectory(prefix="compose-check-") as tmp:
        project = Path(tmp)
        shutil.copy(base, project / "docker-compose.yml")
        for name in BASE_FILES:
            shutil.copy(REPO / name, project / name)
        env_file = project / ".env"
        env_file.write_text("".join(f"{k}={v}\n" for k, v in DUMMY_ENV.items()))
        (project / "cloudflared.env").write_text("TUNNEL_TOKEN=dummy-token\n")
        (project / "data").mkdir()
        (project / "certs").mkdir()
        (project / "custom-templates").mkdir()

        base_f = project / "docker-compose.yml"
        ov = project / "docker-compose.override.yml"
        vps = project / "docker-compose.vps.yml"
        tun = project / "docker-compose.tunnel.yml"
        pod = project / "docker-compose.podman.yml"
        bp = project / "docker-compose.blueprint.yml"

        combos = [
            ("docker", "vps", False, [base_f, ov, vps]),
            ("docker", "vps", True, [base_f, ov, vps, bp]),
            ("docker", "tunnel", False, [base_f, ov, tun]),
            ("docker", "tunnel", True, [base_f, ov, tun, bp]),
            ("podman", "vps", False, [base_f, ov, vps, pod]),
            ("podman", "vps", True, [base_f, ov, vps, pod, bp]),
            ("podman", "tunnel", False, [base_f, ov, tun, pod]),
            ("podman", "tunnel", True, [base_f, ov, tun, pod, bp]),
        ]

        for runtime, mode, blueprint, files in combos:
            tag = f"{runtime}/{mode}/blueprint-{'on' if blueprint else 'off'}"
            profile = "tunnel" if mode == "tunnel" else None
            proc = run_config(compose_bin, project, env_file, files, profile)
            check(proc.returncode == 0, f"{tag}: config exits 0")
            if proc.returncode != 0:
                print("  stderr: " + proc.stderr.strip()[-500:])
                continue
            try:
                model = json.loads(proc.stdout)
            except json.JSONDecodeError:
                check(False, f"{tag}: config output is JSON")
                continue
            services = model.get("services", {})

            check(
                ports_of(services["server"]) == [("9000", "9000", "127.0.0.1")],
                f"{tag}: server publishes only 127.0.0.1:9000:9000",
            )
            check(
                ports_of(services["poznote"]) == [("8040", "80", "127.0.0.1")],
                f"{tag}: poznote publishes only 127.0.0.1:8040:80",
            )
            caddy_ports = ports_of(services["caddy"])
            if mode == "vps":
                check(
                    caddy_ports == [("443", "443", ""), ("80", "80", "")],
                    f"{tag}: VPS Caddy publishes 80/443",
                )
            else:
                check(caddy_ports == [], f"{tag}: tunnel Caddy publishes no ports")

            worker = services["worker"]
            worker_targets = volume_targets(worker)
            has_socket = "/var/run/docker.sock" in worker_targets
            if runtime == "podman":
                check(not has_socket, f"{tag}: Podman worker has no socket mount")
                check(
                    worker_targets == ["/certs", "/data", "/templates"],
                    f"{tag}: Podman worker has exactly data/certs/templates binds",
                )
            else:
                check(has_socket, f"{tag}: Docker worker keeps upstream socket mount")
                check(
                    "/data" in worker_targets
                    and "/certs" in worker_targets
                    and "/templates" in worker_targets,
                    f"{tag}: Docker worker keeps shared binds",
                )

            bp_entries = [
                v
                for v in worker.get("volumes") or []
                if v.get("target") == "/blueprints/custom/demo.yaml"
            ]
            if blueprint:
                check(
                    len(bp_entries) == 1
                    and bp_entries[0].get("read_only", False) is True
                    and str(bp_entries[0].get("source") or "").endswith(
                        "blueprint.yaml"
                    ),
                    f"{tag}: blueprint mount present (read-only)",
                )
            else:
                check(
                    not bp_entries,
                    f"{tag}: no blueprint mount without opt-in",
                )

            if mode == "tunnel":
                check(
                    "cloudflared" in services, f"{tag}: cloudflared service present"
                )
                check(
                    services["cloudflared"].get("profiles") == ["tunnel"],
                    f"{tag}: cloudflared keeps tunnel profile",
                )

        # Missing public-host variables must fail interpolation.
        bare_env = project / ".env.bare"
        bare_env.write_text(
            "PG_PASS=x\nAUTHENTIK_SECRET_KEY=y\nAUTHENTIK_ERROR_REPORTING__ENABLED=false\n"
        )
        for mode, files in (("vps", [base_f, ov, vps]), ("tunnel", [base_f, ov, tun])):
            proc = run_config(
                compose_bin,
                project,
                bare_env,
                files,
                "tunnel" if mode == "tunnel" else None,
            )
            check(proc.returncode != 0, f"missing-hosts/{mode}: interpolation fails")

        # Repo overlays must not rely on short image names.
        for name in (
            "docker-compose.override.yml",
            "docker-compose.tunnel.yml",
        ):
            text = (REPO / name).read_text()
            short = [
                line.strip()
                for line in text.splitlines()
                if line.strip().startswith("image:")
                and "://" not in line
                and line.split("image:")[1].strip().count("/") == 0
            ]
            check(not short, f"{name}: no unqualified short image names ({short})")

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s).")
        return 1
    print("\nAll compose checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
