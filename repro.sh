#!/usr/bin/env bash
# Reproduces: `wmill sync push` never reaches "0 changes" on an unchanged tree.
# Requires WM_LICENSE_KEY (EE: codebases) in the environment.
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
PORT=${WM_PORT:-48100}
wmill() {
  docker compose run --rm -T cli \
    --base-url http://server:8000 --token superadmin-secret --workspace "$WS" "$@"
}

docker compose up -d --wait
docker compose exec -T minio sh -c 'mc alias set m http://localhost:9000 minioadmin minioadmin >/dev/null && mc mb --ignore-existing m/windmill'

# Instance object store (MinIO): codebase bundles are stored there.
curl -sSf -X POST -H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json" \
  "http://localhost:$PORT/api/settings/global/object_store_cache_config" \
  -d '{"value":{"type":"S3","bucket":"windmill","region":"us-east-1","endpoint":"http://minio:9000","access_key":"minioadmin","secret_key":"minioadmin","allow_http":true,"path_style":true}}'
echo
sleep 15  # let server and workers reload the setting

for i in 1 2 3; do
  echo
  echo "================ push #$i ================"
  wmill sync push --yes
  sleep 5
done

echo
echo "== Remote state (versions = deployed script versions)"
for p in f/codebase/multi_output f/plain/empty_schema; do
  curl -sS -H "Authorization: Bearer superadmin-secret" "http://localhost:$PORT/api/w/$WS/scripts/get/p/$p" \
    | jq -c '{path, codebase, schema}'
  echo -n "  versions: "
  curl -sS -H "Authorization: Bearer superadmin-secret" "http://localhost:$PORT/api/w/$WS/scripts/history/p/$p" | jq length
done
