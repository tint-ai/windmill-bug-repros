#!/usr/bin/env bash
# Reproduces: a dedicated flow never uses its runners for `type: script` steps.
# Requires WM_LICENSE_KEY (EE: dedicated workers) in the environment.
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
PORT=${WM_PORT:-48200}
API=http://localhost:$PORT/api
RUNS=5

api() { curl -sSf -H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json" "$@"; }
sql() { docker compose exec -T db psql -U postgres -d windmill -tA -c "$1"; }
dlogs() { docker compose logs --no-log-prefix --since "$1" worker-dedicated 2>/dev/null; }
now() { date -u +%FT%TZ; }

# Waits until the queue is empty and the dedicated worker has restarted after
# $1 (and after the last dependency job), with $2 runner processes started.
wait_ready() {
  local since=$1 want=$2 i s tail
  for i in $(seq 120); do
    sleep 2
    [ "$(sql 'select count(*) from v2_job_queue')" = 0 ] || continue
    s=$(sql "select to_char(greatest('$since'::timestamptz, coalesce(max(c.completed_at), '$since'::timestamptz)) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
             from v2_job j join v2_job_completed c using(id) where j.kind in ('dependencies','flowdependencies')")
    tail=$(dlogs "$s" | awk '/listening for jobs/ {buf=""; seen=1} seen {buf=buf $0 "\n"} END {printf "%s", buf}')
    [ -n "$tail" ] || continue
    grep -q 'exiting' <<<"$tail" && continue
    [ "$(grep -c 'dedicated worker process started' <<<"$tail")" -ge "$want" ] && return 0
  done
  echo "dedicated worker did not come back" >&2; exit 1
}

# Runs the flow $RUNS times, then prints every step job with how it was dispatched.
run_flow() {
  local since ids=() id i
  since=$(now)
  for i in $(seq "$RUNS"); do
    id=$(api -X POST "$API/w/$WS/jobs/run/f/f/r/flow" -d '{"x":1}')
    ids+=("$id")
    until [ "$(sql "select count(*) from v2_job_completed where id='$id'")" = 1 ]; do sleep 1; done
  done
  sleep 2
  local logs; logs=$(dlogs "$since")
  printf '%-4s %-5s %-14s %-10s %-12s %s\n' run step runnable_path worker duration_ms dispatch
  i=0
  for id in "${ids[@]}"; do
    i=$((i + 1))
    sql "select j.id, j.flow_step_id, j.runnable_path, split_part(c.worker, '-', 2), c.duration_ms
         from v2_job j join v2_job_completed c using(id) where j.parent_job='$id' order by j.created_at" |
    while IFS='|' read -r jid step rpath worker dur; do
      if grep -q "on dedicated worker for .*: $jid" <<<"$logs"; then d="runner ($(grep -o "on dedicated worker for [^:]*: $jid" <<<"$logs" | sed 's/on dedicated worker for \([^:]*\):.*/\1/'))"
      elif grep -q "child process 'bun run' took .*job_id=$jid" <<<"$logs"; then d="bun run ($(grep -o "child process 'bun run' took [0-9]*ms job_id=$jid" <<<"$logs" | grep -o 'took [0-9]*ms'))"
      else d="?"; fi
      printf '%-4s %-5s %-14s %-10s %-12s %s\n' "$i" "$step" "$rpath" "$worker" "$dur" "$d"
    done
  done
  echo
  echo "Dispatch lines in the dedicated worker log for these runs:"
  echo "  'on dedicated worker for f/r/echo:'   $(grep -c 'on dedicated worker for f/r/echo:' <<<"$logs" || true)"
  echo "  'on dedicated worker for f/r/flow/c:' $(grep -c 'on dedicated worker for f/r/flow/c:' <<<"$logs" || true)"
  echo "  'child process 'bun run' took'        $(grep -c "child process 'bun run' took" <<<"$logs" || true)"
}

docker compose up -d --wait

echo "== Deploy script f/r/echo and flow f/r/flow (dedicated_worker: true)"
jq -n --rawfile c f/echo.ts '{path: "f/r/echo", summary: "", description: "", language: "bun", content: $c,
  schema: {"$schema": "https://json-schema.org/draft/2020-12/schema", type: "object", properties: {x: {type: "number"}}, required: ["x"]}}' |
  api -X POST "$API/w/$WS/scripts/create" -d @- >/dev/null
jq '.path = "f/r/flow"' f/flow.json | api -X POST "$API/w/$WS/flows/create" -d @- >/dev/null

until TAG=$(sql "select tag from v2_job where kind='flowdependencies' order by created_at desc limit 1") && [ -n "$TAG" ]; do sleep 1; done
echo "flow tag (from its flowdependencies job): $TAG"

echo
echo "== Worker group 'dedicated': flow entry only"
T=$(now)
CONFIG=$(jq -nc --arg t "$TAG" '{dedicated_workers: ["admins:flow/f/r/flow"], worker_tags: [$t]}')
echo "$CONFIG"
api -X POST "$API/configs/update/worker__dedicated" -d "$CONFIG"; echo
wait_ready "$T" 2
dlogs "$T" | awk '/listening for jobs/ {buf=""; seen=1} seen {buf=buf $0 "\n"} END {printf "%s", buf}' |
  grep -E 'spawned dedicated worker|dedicated worker process started' | sed 's/^[^ ]* *INFO //'

echo
echo "== $RUNS flow runs"
run_flow

echo
echo "== Workaround: also list the step script in the worker group"
T=$(now)
CONFIG=$(jq -nc --arg t "$TAG" '{dedicated_workers: ["admins:flow/f/r/flow", "admins:f/r/echo"], worker_tags: [$t]}')
echo "$CONFIG"
api -X POST "$API/configs/update/worker__dedicated" -d "$CONFIG"; echo
wait_ready "$T" 3
dlogs "$T" | awk '/listening for jobs/ {buf=""; seen=1} seen {buf=buf $0 "\n"} END {printf "%s", buf}' |
  grep -E 'spawned dedicated worker|dedicated worker process started' | sed 's/^[^ ]* *INFO //'

echo
echo "== $RUNS flow runs"
run_flow
