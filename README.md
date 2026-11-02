# Codebase script loses its bundle after a lib relock

When a lib's lockfile changes, the server relocks the scripts that import it. For a script deployed as a codebase bundle, that relock deploys a new version whose bundle doesn't exist, and the script can no longer run.

Tested on Windmill server and CLI 1.847.0 (EE), Bun scripts.

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

- **Step 0 is needed.** A script pushed straight into a codebase doesn't get a `dependency_map` row for its relative imports, so no relock happens. The row recorded while the script was plain stays after it moves to the codebase. This is how existing scripts get migrated to codebases.
- **Only a lockfile change triggers the relock.** A code-only edit to the lib doesn't, because the `dependency_map` row stores an `imported_lockfile_hash`. In our workspace the libs import `"@hermes/axiom": "latest"`, so their locks change often.
- **`wmill sync push` hides the bug here.** The CLI hashes the whole codebase folder, so a sync push re-uploads `hello`'s bundle with the lib. With 497 scripts in our real push, 66 ended up broken, most likely because the relock jobs ran after the CLI's upload for those scripts.

## Expected

A codebase script already has its dependencies inside its bundle. The relock on lib change should either skip it, or carry the bundle over to the new version.
