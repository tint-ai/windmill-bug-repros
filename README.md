# Migrating a script into a codebase keeps its `dependency_map` rows; a later lib relock deploys it without a bundle

A script deployed as a plain script gets `dependency_map` rows for the workspace scripts it imports. Those rows stay after the script moves into a codebase. When an imported lib's lockfile later changes, the server relocks the codebase script and deploys a version whose bundle doesn't exist, so every run fails.

Migrating existing scripts is how a workspace adopts codebases, so every adopter hits this path. In our workspace, one push broke 66 of 497 codebase scripts.

Reproduced with Bun scripts on Windmill EE server and CLI 1.847.0, and on the latest release: server 1.862.0 with CLI 1.862.1 (2026-11-06). The compose file pins 1.847.0; both versions fail the same way.

## Layout

```
wmill.yaml                # codebase: relative_path f, format esm, includes f/app/**
f/app/hello.ts            # codebase script, imports ../shared/lib/format.ts
f/shared/lib/format.ts    # plain workspace script (no_main_func), imports dayjs
docker-compose.yml        # Postgres, MinIO, Windmill EE server + workers, wmill CLI
repro.sh                  # the steps below
```

MinIO is required: the server refuses to create a codebase script without an instance object store.

## Run

```sh
WM_LICENSE_KEY=<ee-license> ./repro.sh
```

`repro.sh` uses the `admins` workspace and the superadmin token. It does:

0. Pushes `f/app/hello` as a plain script. The server records that it imports `f/shared/lib/format`.
1. Pushes again with the codebase. `f/app/hello` is deployed as an esm bundle and runs.
2. Adds an npm import to `f/shared/lib/format.ts` and pushes only the lib with `wmill script push`.
3. The server runs a `dependencies` job on `f/app/hello`. It deploys a new version that keeps the `codebase` field and gets a lock, but no bundle is uploaded for its hash.
4. Running `f/app/hello` fails:

```
execution error:
Failed to pull bytes from object store: script_bundle/admins/a79c60912e469e23.esm
```

## Notes

- **Step 0 is the trigger.** A script pushed straight into a codebase gets no `dependency_map` row for its relative imports, so the server never relocks it. Only the rows left from its time as a plain script cause the relock.
- **Only a lockfile change triggers the relock.** A code-only edit to the lib doesn't, because the `dependency_map` row stores an `imported_lockfile_hash`. In our workspace the libs import `"@hermes/axiom": "latest"`, so their locks change often.
- **`wmill sync push` hides the bug here.** The CLI hashes the whole codebase folder, so a sync push re-uploads `hello`'s bundle with the lib. With 497 scripts in our real push, 66 ended up broken, most likely because the relock jobs ran after the CLI's upload for those scripts.

## Expected

The Windmill server runs the relock on its own: when a lib's lock changes, it reads `dependency_map` and queues a `dependencies` job for every script that imports the lib. The job doesn't check whether the script is a codebase bundle, and the server can't re-bundle, so it deploys a version with a new lock and no bundle.

A codebase script carries the lib's code and its npm packages inside its bundle, and the CLI rebuilds that bundle on push. It needs no server-side relock. Two fixes would prevent the failure:

1. **Clear the rows on codebase deploy.** When a codebase script is deployed, remove its `dependency_map` rows, as the server already refreshes them on plain deploys. This fixes the root cause.
2. **Make the relock safe for codebase scripts.** If a `dependencies` job targets a codebase script, skip it or carry the previous bundle over, so the job never deploys a version without a bundle.

## Workaround

After migrating scripts into a codebase, delete their leftover rows before any lib lock changes (untested sketch):

```sql
DELETE FROM dependency_map d
USING script s
WHERE d.importer_kind = 'script'
  AND s.workspace_id = d.workspace_id
  AND s.path = d.importer_path
  AND s.codebase IS NOT NULL
  AND NOT s.archived;
```

Then run `wmill sync push` again to repair scripts already relocked without a bundle.
