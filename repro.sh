#!/usr/bin/env bash
# Reproduces: one edit anywhere under a codebase's relative_path re-bundles and
# re-uploads every script of that codebase. Requires WM_LICENSE_KEY (EE).
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
API="http://localhost:${WM_PORT:-48000}/api"
AUTH=(-H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json")
SCRIPTS=(a b c)

wmill() {
  docker compose run --rm -T cli \
    --base-url http://server:8000 --token superadmin-secret --workspace "$WS" "$@"
}
hash_of() {
  curl -sS "${AUTH[@]}" "$API/w/$WS/scripts/get/p/f/app/$1" | sed -E 's/.*"hash":"([^"]+)".*/\1/'
}
bundles() {
  docker compose exec -T minio sh -c 'mc ls --recursive m/windmill/script_bundle/ 2>/dev/null | wc -l'
}
# push <expected redeploys>: pushes, then compares redeployed scripts with the expected ones.
push() {
  local expected=$1 before=() actual="" s i=0
  for s in "${SCRIPTS[@]}"; do before+=("$(hash_of "$s" 2>/dev/null || true)"); done
  wmill sync push --yes 2>&1 | sed "s/\x1b\[[0-9;]*m//g" | grep -E "changes to apply" || true
  for s in "${SCRIPTS[@]}"; do
    [ "$(hash_of "$s")" != "${before[$i]}" ] && actual+="f/app/$s "
    i=$((i + 1))
  done
  echo "  expected redeploys: ${expected:-none}"
  echo "  actual redeploys:   ${actual:-none}"
  echo "  bundles stored:     $(bundles)"
}

docker compose up -d --wait
docker compose exec -T minio sh -c 'mc alias set m http://localhost:9000 minioadmin minioadmin >/dev/null && mc mb --ignore-existing m/windmill'
curl -sSf -X POST "${AUTH[@]}" "$API/settings/global/object_store_cache_config" \
  -d '{"value":{"type":"S3","bucket":"windmill","region":"us-east-1","endpoint":"http://minio:9000","access_key":"minioadmin","secret_key":"minioadmin","allow_http":true,"path_style":true}}'
echo
sleep 15  # let the server reload the setting

restore() { git checkout -- f/app/a.spec.ts f/app/lib/greet.ts 2>/dev/null || true; }
trap restore EXIT

echo "== 1. First push"
push "f/app/a f/app/b f/app/c "

echo "== 2. Push again, nothing changed (control)"
push ""

echo "== 3. Edit a comment in f/app/a.spec.ts (excluded from sync, imported by nothing)"
sed -i 's|^// Test file.*|// Test file (edited comment).|' f/app/a.spec.ts
push ""

echo "== 4. Edit f/app/lib/greet.ts (bundled into f/app/a only)"
sed -i 's|hello |hi |' f/app/lib/greet.ts
push "f/app/a "
