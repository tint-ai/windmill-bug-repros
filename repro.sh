#!/usr/bin/env bash
# Reproduces: a lib push triggers a dependency job that redeploys codebase
# scripts without their bundle. Requires WM_LICENSE_KEY (EE) in the environment.
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
wmill() {
  docker compose run --rm -T cli \
    --base-url http://server:8000 --token superadmin-secret --workspace "$WS" "$@"
}
run_hello() {
  curl -sS -X POST -H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json" \
    "http://localhost:${WM_PORT:-48000}/api/w/$WS/jobs/run_wait_result/p/f/app/hello" -d '{"name":"repro"}'
  echo
}

docker compose up -d --wait
docker compose exec -T minio sh -c 'mc alias set m http://localhost:9000 minioadmin minioadmin >/dev/null && mc mb --ignore-existing m/windmill'
docker compose run --rm -T --entrypoint bun cli install

# Instance object store (MinIO): codebase bundles are stored there.
curl -sSf -X POST -H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json" \
  "http://localhost:${WM_PORT:-48000}/api/settings/global/object_store_cache_config" \
  -d '{"value":{"type":"S3","bucket":"windmill","region":"us-east-1","endpoint":"http://minio:9000","access_key":"minioadmin","secret_key":"minioadmin","allow_http":true,"path_style":true}}'
echo
sleep 15  # let server and workers reload the setting

echo "== 0. Push f/app/hello as a plain script, before it joins the codebase"
# This records the f/app/hello -> f/shared/lib/format import on the server.
cp wmill.yaml wmill.yaml.bak
sed -i '/^codebases:/,$d' wmill.yaml
wmill sync push --yes
mv wmill.yaml.bak wmill.yaml
sleep 10

echo "== 1. Push with the codebase: f/app/hello is deployed as an esm bundle"
wmill sync push --yes
sleep 10
run_hello   # OK

echo "== 2. Add an npm dependency to the lib and push only the lib"
# A lockfile change in the lib makes the server relock its importers.
cp f/shared/lib/format.ts f/shared/lib/format.ts.bak
trap 'mv f/shared/lib/format.ts.bak f/shared/lib/format.ts' EXIT
printf '\nimport ms from "ms";\nexport const TIMEOUT = ms("2 days");\n' >> f/shared/lib/format.ts
wmill script push f/shared/lib/format.ts

echo "== 3. Wait for the dependencies job on f/app/hello"
sleep 30

echo "== 4. Run the codebase script again"
# Fails with: Failed to pull bytes from object store: script_bundle/<ws>/<hash>.esm
run_hello
