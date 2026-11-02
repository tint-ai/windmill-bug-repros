#!/usr/bin/env bash
# Reproduces: one edit anywhere under a codebase's relative_path re-bundles and
# re-uploads every script of that codebase. Requires WM_LICENSE_KEY (EE).
set -euo pipefail
cd "$(dirname "$0")"

WS=admins
API="http://localhost:${WM_PORT:-48000}/api"
AUTH=(-H "Authorization: Bearer superadmin-secret" -H "Content-Type: application/json")

wmill() {
  docker compose run --rm -T cli \
    --base-url http://server:8000 --token superadmin-secret --workspace "$WS" "$@"
}
push() {
  wmill sync push --yes 2>&1 | grep -E "changes to apply|Codebase f/app, digest|(Updated|Created new) script" || true
}
hashes() {
  for s in a b c; do
    printf '  f/app/%s  %s\n' "$s" "$(curl -sS "${AUTH[@]}" "$API/w/$WS/scripts/get/p/f/app/$s" | sed -E 's/.*"hash":"([^"]+)".*/\1/')"
  done
}
bundles() {
  docker compose exec -T minio sh -c 'mc ls --recursive m/windmill/script_bundle/ 2>/dev/null | wc -l'
}

docker compose up -d --wait
docker compose exec -T minio sh -c 'mc alias set m http://localhost:9000 minioadmin minioadmin >/dev/null && mc mb --ignore-existing m/windmill'
curl -sSf -X POST "${AUTH[@]}" "$API/settings/global/object_store_cache_config" \
  -d '{"value":{"type":"S3","bucket":"windmill","region":"us-east-1","endpoint":"http://minio:9000","access_key":"minioadmin","secret_key":"minioadmin","allow_http":true,"path_style":true}}'
echo
sleep 15  # let the server reload the setting

restore() { git checkout -- f/app/a.spec.ts f/app/lib/greet.ts 2>/dev/null || true; }
trap restore EXIT

echo "== 1. First push: 3 codebase scripts created"
push
hashes; echo "  bundles in object store: $(bundles)"

echo "== 2. Push again, nothing changed (control)"
push

echo "== 3. Edit a comment in f/app/a.spec.ts (excluded from sync, imported by nothing)"
sed -i 's|^// Test file.*|// Test file (edited comment).|' f/app/a.spec.ts
push
hashes; echo "  bundles in object store: $(bundles)"

echo "== 4. Edit f/app/lib/greet.ts (bundled into f/app/a only)"
sed -i 's|hello |hi |' f/app/lib/greet.ts
push
hashes; echo "  bundles in object store: $(bundles)"
