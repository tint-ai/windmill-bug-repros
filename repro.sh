#!/usr/bin/env bash
# Reproduces: an error thrown on a dedicated Bun runner loses step_id, flow_path and extra.
# Requires WM_LICENSE_KEY (EE: dedicated workers) in the environment.
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
PORT=${WM_PORT:-48300}
API=http://localhost:$PORT/api

api() { curl -sSf -H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json" "$@"; }
sql() { docker compose exec -T db psql -U postgres -d windmill -tA -c "$1"; }
dlogs() { docker compose logs --no-log-prefix --since "$1" worker-dedicated 2>/dev/null; }
now() { date -u +%FT%TZ; }
after_last_start() { awk '/listening for jobs/ {buf=""; seen=1} seen {buf=buf $0 "\n"} END {printf "%s", buf}'; }

# Waits until the queue is empty and the dedicated worker has restarted after
# $1 (and after the last dependency job), with $2 runner processes started.
wait_ready() {
  local since=$1 want=$2 i s tail
  for i in $(seq 120); do
    sleep 2
    [ "$(sql 'select count(*) from v2_job_queue')" = 0 ] || continue
    s=$(sql "select to_char(greatest('$since'::timestamptz, coalesce(max(c.completed_at), '$since'::timestamptz)) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
             from v2_job j join v2_job_completed c using(id) where j.kind in ('dependencies','flowdependencies')")
    tail=$(dlogs "$s" | after_last_start)
    [ -n "$tail" ] || continue
    grep -q 'exiting' <<<"$tail" && continue
    [ "$(grep -c 'dedicated worker process started' <<<"$tail")" -ge "$want" ] && return 0
  done
  echo "dedicated worker did not come back" >&2; exit 1
}

# Runs script or flow $1 (p/<path> or f/<path>), waits, prints the worker and the result.
run() {
  local id
  id=$(api -X POST "$API/w/$WS/jobs/run/$1" -d '{}')
  until [ "$(sql "select count(*) from v2_job_completed where id='$id'")" = 1 ]; do sleep 1; done
  echo "$id"
}

show_script() {
  local id=$1
  echo "worker: $(sql "select worker from v2_job_completed where id='$id'")"
  echo "result: $(sql "select result from v2_job_completed where id='$id'")"
  echo "error keys: $(sql "select result->'error' from v2_job_completed where id='$id'" | jq -c 'keys')"
}

show_flow() {
  local id=$1
  sql "select j.flow_step_id || ' ' || c.status || ' ' || c.worker from v2_job j join v2_job_completed c using(id) where j.parent_job='$id' order by j.created_at" |
    sed 's/^/step job: /'
  echo "step a error keys: $(sql "select c.result->'error' from v2_job j join v2_job_completed c using(id) where j.parent_job='$id' and j.flow_step_id='a'" | jq -c 'keys')"
  echo "failure module received: $(sql "select c.result from v2_job j join v2_job_completed c using(id) where j.parent_job='$id' and j.flow_step_id='failure'")"
}

docker compose up -d --wait

echo "== Deploy"
SCHEMA='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{},"required":[]}'
for s in "f/r/boom false" "f/r/boom_ded true"; do
  set -- $s
  jq -n --rawfile c f/boom.ts --arg p "$1" --argjson d "$2" --argjson schema "$SCHEMA" \
    '{path: $p, summary: "", description: "", language: "bun", content: $c, schema: $schema, dedicated_worker: $d}' |
    api -X POST "$API/w/$WS/scripts/create" -d @- >/dev/null
  echo "script $1 (dedicated_worker: $2)"
done
# Same flow twice: f/r/flow on default workers, f/r/flow_ded flagged dedicated.
jq '.path = "f/r/flow" | .value.modules[0].value.path = "f/r/boom"' f/flow.json |
  api -X POST "$API/w/$WS/flows/create" -d @- >/dev/null
echo "flow f/r/flow: step a = f/r/boom"
jq '.path = "f/r/flow_ded" | .dedicated_worker = true | .value.modules[0].value.path = "f/r/boom_ded"' f/flow.json |
  api -X POST "$API/w/$WS/flows/create" -d @- >/dev/null
echo "flow f/r/flow_ded (dedicated_worker: true): step a = f/r/boom_ded"

until FLOW_TAG=$(sql "select tag from v2_job where kind='flowdependencies' and runnable_path='f/r/flow_ded' limit 1") && [ -n "$FLOW_TAG" ]; do sleep 1; done
SCRIPT_TAG=$WS:f/r/boom_ded
echo "tags: $SCRIPT_TAG (script), $FLOW_TAG (flow, from its flowdependencies job)"

# The flow entry starts runners for its steps. The script entry is needed too:
# without it, step `a` (a `type: script` step) does not reach a runner.
T=$(now)
CONFIG=$(jq -nc --arg s "$SCRIPT_TAG" --arg f "$FLOW_TAG" \
  '{dedicated_workers: ["admins:f/r/boom_ded", "admins:flow/f/r/flow_ded"], worker_tags: [$s, $f]}')
echo "worker group 'dedicated': $CONFIG"
api -X POST "$API/configs/update/worker__dedicated" -d "$CONFIG" >/dev/null
wait_ready "$T" 2
dlogs "$T" | after_last_start | grep -E 'spawned dedicated worker|dedicated worker process started' | sed 's/^[^ ]* *INFO //'

echo
echo "================ 1. script f/r/boom, default worker"
show_script "$(run p/f/r/boom)"

echo
echo "================ 2. script f/r/boom_ded, dedicated runner"
T=$(now)
ID=$(run p/f/r/boom_ded)
show_script "$ID"
dlogs "$T" | grep "$ID" | grep -E "on dedicated worker for|bun run" | sed 's/^[^ ]* *INFO //' | cut -c1-160

echo
echo "================ 3. flow f/r/flow, default worker"
show_flow "$(run f/f/r/flow)"

echo
echo "================ 4. flow f/r/flow_ded, dedicated runners"
T=$(now)
ID=$(run f/f/r/flow_ded)
show_flow "$ID"
dlogs "$T" | grep -E "on dedicated worker for|bun run" | sed 's/^[^ ]* *INFO //' | cut -c1-160
