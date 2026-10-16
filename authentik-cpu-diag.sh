#!/usr/bin/env bash
# authentik CPU diagnosis — READ-ONLY evidence collector.
# Nothing is created, modified, or deleted under /opt/authentik; no container
# restarts; no state mutation. Only output file: /tmp/authentik-diag.txt.
#
# If your SSH user is NOT in the docker group (README installs use
# `sudo docker compose`), run as-is. If you ARE in the docker group, run with
# SUDO= so no password prompt appears:
#     SUDO= APP_DIR=/opt/authentik bash /tmp/authentik-cpu-diag.sh
set -u
export LC_ALL=C
APP_DIR="${APP_DIR:-/opt/authentik}"
OUT="${OUT:-/tmp/authentik-diag.txt}"
SUDO="${SUDO-sudo}"
W1="${W1:-20}"   # seconds between the two docker stats snapshots
W2="${W2:-8}"    # seconds for the per-thread jiffies delta

cd "$APP_DIR" 2>/dev/null || { echo "FATAL: cd '$APP_DIR' failed; set APP_DIR=<dir>"; exit 1; }
DC="$SUDO docker compose"
DK="$SUDO docker"

# --------------------------------------------------------------------------
section(){ printf '\n===== [%s] %s =====\n' "$1" "$2"; }
note(){ printf '# %s\n' "$1"; }
run(){ echo "\$ $*"; "$@" 2>&1 | sed -n '1,150p'; }
srvc(){ $DC ps -q "$1" 2>/dev/null | head -1; }
pid_of(){ local c; c=$(srvc "$1"); [ -n "$c" ] && $DK inspect -f '{{.State.Pid}}' "$c" 2>/dev/null; }

# CPU accounting from /proc — no tooling needed inside the container.
# Strip "pid (comm) " so utime/stime (orig fields 14/15) land at 12/13.
cpu_j(){ local raw; raw=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
        raw=${raw##*) }; echo $(( $(awk '{print $12+$13}' <<<"$raw") )); }

{
section S1 HOST
run date; run uptime; run nproc
note "host load + mem"; run cat /proc/loadavg; run free -m

section S2 COMPOSE-FILES
note "COMPOSE_FILE decides whether the blueprint (and thus outpost config) is live"
grep -E '^(COMPOSE_FILE|COMPOSE_PROFILES)=' .env 2>&1 || echo "(not in .env)"
note "overlay files present in $APP_DIR"
for f in docker-compose.tunnel.yml docker-compose.blueprint.yml docker-compose.override.yml; do
  [ -f "$f" ] && echo "present: $f" || echo "MISSING: $f"
done

section S3 CONTAINERS-IMAGES-RESTARTS
$DC ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1 | sed -n '1,40p'
note "image tags (version facts) + restart counts"
for s in server worker postgresql cloudflared caddy; do
  cid=$(srvc "$s"); [ -z "$cid" ] && { echo "$s: (not running)"; continue; }
  $DK inspect -f '{{.Config.Image}} | {{.RestartCount}} restarts | started {{.State.StartedAt}}' \
    "$cid" 2>/dev/null | sed "s|^|$s |"
done
note "worker mounts (blueprint.yaml mounted => blueprint overlay live)"
srvc worker | xargs -r $DK inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null

section S4 CPU-SNAPSHOT-1
note "averaged since container start — inflated if recently restarted"
run $DK stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}'

section S5 CPU-SNAPSHOT-2
note "${W1}s later — this one is real-time"
sleep "$W1"
run $DK stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}'

section S6 HOT-THREADS
note "main-pid jiffies delta over ${W2}s + top threads by cumulative CPU"
for s in server worker postgresql; do
  pid=$(pid_of "$s"); [ -z "$pid" ] && { echo "$s: (no pid)"; continue; }
  a=$(cpu_j "$pid"); sleep "$W2"; b=$(cpu_j "$pid")
  echo "$s: main pid $pid, +$((b-a)) jiffies in ${W2}s"
  for t in /proc/$pid/task/*; do
    [ -r "$t/stat" ] || continue
    tid=${t##*/}; j=$(cpu_j "$tid"); echo "$j $tid"
  done | sort -rn | head -8 | while read -r j tid; do
    echo "   tid=$tid jiffies=$j cmd=$(tr -d '\0' </proc/$pid/task/$tid/cmdline 2>/dev/null | cut -c1-60)"
  done
done

section S7 HEALTH
run curl -fsS --max-time 5 http://127.0.0.1:9000/-/health/live/
h=$(grep -E '^AUTH_PUBLIC_HOST=' .env | cut -d= -f2-)
note "AUTH_PUBLIC_HOST from .env (value shown here only)"
echo "host=${h:-<empty>}"
if [ -n "$h" ]; then
  run curl -s -o /dev/null --max-time 10 -w 'public /-/health/live/ -> %{http_code} in %{time_total}s\n' "https://$h/-/health/live/"
fi

section S8 SELF-DIAL-FROM-SERVER
note "can the server container resolve + reach its own public URL? (Branch A discriminator)"
cid=$(srvc server)
if [ -n "$cid" ] && [ -n "$h" ]; then
  $DK exec -i "$cid" sh -c "getent hosts $h || echo DNS-FAIL; curl -s -o /dev/null --max-time 8 -w 'self-http %{http_code} in %{time_total}s\n' https://$h/-/health/live/ || echo SELF-DIAL-FAIL" 2>&1
else
  echo "(skipped: server not running or AUTH_PUBLIC_HOST empty)"
fi

section S9 TUNNEL
run $DC --profile tunnel ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}' cloudflared
note "cloudflared last 40 lines"
$DC logs --tail 40 --timestamps cloudflared 2>&1 | sed -n '1,40p'

section S10 LOG-CADENCE
note "per-minute counts; ~60min ticks = blueprint scan, NOT the CPU cause"
for s in server worker postgresql cloudflared; do
  echo "--- $s ---"
  $DC logs --since 30m --timestamps "$s" 2>&1 \
    | grep -iE 'error|retry|reconnect|outpost|refus|timeout|traceback' \
    | awk '{print substr($1,1,16)}' | uniq -c | tail -20
done

section S11 LOG-TAILS
note "worker last 60 (blueprint tracebacks land here)"
$DC logs --tail 60 --timestamps worker 2>&1 | sed -n '1,60p'
note "server last 60 (outpost 'Failed to fetch outpost configuration' lands here)"
$DC logs --tail 60 --timestamps server 2>&1 | sed -n '1,60p'
note "postgresql last 25"
$DC logs --tail 25 --timestamps postgresql 2>&1 | sed -n '1,25p'

section S12 ENV-PRESENCE
note "presence only, no values"
for k in AUTH_PUBLIC_HOST POZNOTE_OIDC_CLIENT_ID POZNOTE_OIDC_CLIENT_SECRET; do
  if grep -qE "^${k}=.+" .env 2>/dev/null; then echo "$k: SET"; else echo "$k: MISSING-or-EMPTY"; fi
done
note "env names actually delivered into worker/server (values redacted)"
for s in worker server; do
  cid=$(srvc "$s"); [ -z "$cid" ] && continue
  echo "--- $s ---"
  $DK exec -i "$cid" env 2>/dev/null | grep -E '^(AUTH_PUBLIC_HOST|POZNOTE_OIDC|AUTHENTIK_POSTGRESQL)' \
    | sed -E 's/^([^=]+)=.*/\1=<delivered>/' | sort
done

section S13 POSTGRES
note "JIT flag + least-recently-analyzed tables (issue #24179 style degradation)"
pgc=$(srvc postgresql)
if [ -n "$pgc" ]; then
  pguser=$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-); pguser=${pguser:-authentik}
  pgdb=$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2-); pgdb=${pgdb:-authentik}
  echo "using POSTGRES_USER=$pguser POSTGRES_DB=$pgdb (from .env)"
  $DK exec -i "$pgc" psql -U "$pguser" -d "$pgdb" -tAc \
    "show jit; select 'least analyzed: '||relname||' @ '||coalesce(last_analyze::text,'never') from pg_stat_user_tables order by last_analyze asc nulls first limit 3;" 2>&1 \
    || echo "(psql failed; check POSTGRES_USER/DB in .env)"
  note "connection count"; $DK exec -i "$pgc" psql -U "$pguser" -d "$pgdb" -tAc 'select count(*) from pg_stat_activity;' 2>&1
else echo "(postgresql not running)"; fi

section S14 CONFIG
$DC config --quiet && echo "config: OK" || echo "config: INVALID (see error above)"
} > "$OUT" 2>&1

echo "wrote $OUT ($(wc -l <"$OUT") lines)"
cat "$OUT"
