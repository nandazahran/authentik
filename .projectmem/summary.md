# projectmem - authentik

_Last updated: 2026-10-20_

## Project purpose
[Sekilas Tentang](#sekilas-tentang) | [Instalasi](#instalasi) | [Setelah Instalasi](#setelah-instalasi) | [Konfigurasi](#konfigurasi) | [Otomatisasi](#otomatisasi) | [Penggunaan Lanjutan](#penggunaan-lanjutan) | [Pembahasan](#pembahasan) | [Referensi](#referensi)…

## Recent issues
- [DONE] #legacy_d6d9 Legacy issue: cpu bug notes on manual -> cpu bug notes on manual (fixed)
- [DONE] #legacy_b8ee Legacy issue: readme cpu bug docs update -> readme cpu bug docs update (fixed)
- [DONE] #legacy_7da4 Legacy issue: fix cpu issue -> fix cpu issue (fixed)
- [DONE] #legacy_164a Legacy issue: fix podman stop at step 2 issue -> fix podman stop at step 2 issue (fixed)
- [DONE] #legacy_02df Legacy issue: old state fixes -> old state fixes (fixed)

## Decisions
- No decisions logged yet.

## Notes
- flow readme update 2
- add blueprint error info on README
- logo
- logo addition
- logo update 2
- diagram update
- gotcha: blueprint re-apply is NOT triggered by .env changes. blueprint_hash() (authentik/blueprints/v1/hash.py) hashes file content + !File refs only; !Env values are resolved at apply time and are not hashed. So editing AUTH_PUBLIC_HOST etc. and running 'up -d' leaves providers on old hostnames. Force with 'docker compose exec server ak apply_blueprint /blueprints/custom/demo.yaml' (podman: ./podman-compose.sh exec server ak ...). Verify authentik_blueprints_blueprintinstance.status == successful; blueprint apply is one atomic transaction so 'error' means nothing was written. [README.md:436]
- gotcha: correction to earlier note 'blueprint re-apply is NOT triggered by .env changes'. Path citation was wrong: authentik/blueprints/v1/hash.py does NOT exist at the deployed tag version/2026.8.3 (it exists only on main). At 2026.8.3 the hash is computed in authentik/blueprints/v1/tasks.py blueprints_find() as sha512(path.read_bytes()) -- raw file bytes only, no !File expansion -- and check_blueprint_v1_file() applies only when instance.last_applied_hash != blueprint.hash. !Env resolves at apply time via Env.resolve() -> getenv() in authentik/blueprints/v1/common.py, so env values never enter the hash. Durable conclusion unchanged: editing AUTH_PUBLIC_HOST/TOOLS_PUBLIC_HOST/POZNOTE_PUBLIC_HOST and running 'up -d' does NOT re-apply the blueprint; force with 'exec server ak apply_blueprint /blueprints/custom/demo.yaml' and verify authentik_blueprints_blueprintinstance.status == successful. [authentik/blueprints/v1/tasks.py:144]
- README.md compacted 2026-10-20: single linear install flow (Kebutuhan Sistem -> Docker/Podman -> clone -> Siapkan .env -> Jalankan backend privat -> Bootstrap admin -> Buka ingress A/B -> Integrasi). Opsi A/B no longer duplicate .env+bootstrap steps; runtime Podman handled by one convention block near top plus targeted notes. Keep new content in existing sections instead of adding parallel A/B walkthroughs. [README.md:1]
- README.md compacted 2026-10-20. Structure: shared pre-ingress steps deduped (Siapkan .env, Jalankan backend privat, Bootstrap admin) so Opsi A/B branch only at 'Buka ingress'; runtime Podman handled by one convention block near the top plus targeted notes. Verified with compose v5.6.0 (pinned hash in setup.sh): tunnel overlay resets caddy ports to none and Opsi B needs a plain 'up -d' before the --profile tunnel connector, since cloudflared depends_on caddy. Troubleshooting table kept all 35 rows. [README.md:1]

## Key files
- `Caddyfile`
- `Caddyfile.tunnel`
- `README.md`
- `docker-compose.override.yml`
- `docker-compose.tunnel.yml`
- `docker-compose.vps.yml`
- `setup.sh`
- `VERIFICATION.md`
- `example.md`
- `instruction.md`
- `.gitignore`
- `authentik-cpu-diag.sh`
- `authentik-podman.service`
- `docker-compose.podman.yml`
- `podman-compose.sh`
- `tests/__pycache__/check_compose.cpython-314.pyc`
- `tests/check_compose.py`
- `authentik-diag.txt`
- `blueprint.yaml`
- `authentiklogo.svg`

## Open questions
- None logged yet.
