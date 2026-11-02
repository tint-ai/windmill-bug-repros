#!/usr/bin/env bash
# Reproduces: a lib push triggers a dependency job that redeploys codebase
# scripts without their bundle. Requires LICENSE_KEY (EE) in the environment.
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
wmill() {
  docker compose run --rm -T cli \
    --base-url http://server:8000 --token superadmin-secret --workspace "$WS" "$@"
}
run_hello() {
  curl -sS -X POST -H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json" \
    "http://localhost:18000/api/w/$WS/jobs/run_wait_result/p/f/app/hello" -d '{"name":"repro"}'
  echo
}

docker compose up -d --wait
docker compose run --rm -T --entrypoint bun cli install

echo "== 1. Initial push: f/app/hello is deployed as an esm bundle"
wmill sync push --yes
sleep 10
run_hello   # OK: "[v1] hello repro at ..."

echo "== 2. Change only the lib and push again"
sed -i 's/VERSION = "v1"/VERSION = "v2"/' f/shared/lib/format.ts
trap 'sed -i "s/VERSION = \"v2\"/VERSION = \"v1\"/" f/shared/lib/format.ts' EXIT
wmill sync push --yes

echo "== 3. Wait for the dependencies job on f/app/hello"
sleep 30

echo "== 4. Run the codebase script again"
# Fails with: Failed to pull bytes from object store: script_bundle/<ws>/<hash>.esm
run_hello
