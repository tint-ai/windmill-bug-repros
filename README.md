# One edit in a codebase re-pushes every script

Minimal repro for: the codebase digest covers the whole `relative_path` tree, so editing any file under it re-bundles and re-uploads every script of the codebase, including scripts that don't import the edited file.

Tested on Windmill server and CLI 1.847.0 (EE), Bun scripts.

## Layout

```
.
|__ wmill.yaml            # codebase: relative_path f/app, format esm
|__ f/
    |__ app/
        |__ a.ts          # codebase script, imports ./lib/greet.ts
        |__ a.spec.ts     # test file, imported by nothing (excluded from sync)
        |__ b.ts          # codebase script, no imports
        |__ c.ts          # codebase script, no imports
        |__ lib/
            |__ greet.ts  # helper bundled into a.ts only (excluded from sync)
```

## Steps

Everything runs in Docker: Postgres, MinIO (object store for bundles), Windmill EE server, and the `wmill` CLI (`bunx windmill-cli@1.847.0`).

```sh
WM_LICENSE_KEY=<ee-license> ./repro.sh
```

The script uses the `admins` workspace and the superadmin token. Each step runs `wmill sync push`, then prints the deployed hash of each script and the number of objects under `script_bundle/` in MinIO.

Each redeploy uploads a new bundle and keeps the previous one, so the object count shows the upload and storage cost. At our scale, every push adds 6 GiB.

| Step | Edit | Changes to apply | Scripts redeployed | Bundles stored (cumulative) |
|---|---|---|---|---|
| 1 | first push | 12 | a, b, c | 3 |
| 2 | none | 0 | none | 3 |
| 3 | comment in `f/app/a.spec.ts` | 3 | a, b, c | 6 |
| 4 | `f/app/lib/greet.ts` | 3 | a, b, c | 9 |

Output of step 3:

```
== 3. Edit a comment in f/app/a.spec.ts (excluded from sync, imported by nothing)
Codebase f/app, digest: 9125a50a2c7fcdc0ed58c804fe997a1e27ce797d12fa588fc24824d5d68e5aa8.esm
remote (admins) <- local: 3 changes to apply
Updated script f/app/a (11ms)
Updated script f/app/b (12ms)
Updated script f/app/c (26ms)
  f/app/a  de0e46df9c088a83
  f/app/b  8b394f37ab276c62
  f/app/c  b214725ab3a90ff7
  bundles in object store: 6
```

## Expected

- Step 3 redeploys nothing: no script bundles `a.spec.ts`.
- Step 4 redeploys `f/app/a` only: it is the only script that bundles `greet.ts`.

## Cause

`listSyncCodebases` in `cli/src/utils/codebase.ts` computes one digest per codebase: `digestDir(codebase.relative_path, JSON.stringify(codebase))` plus `extra_digest_paths`. `digestDir` hashes every file in the tree and ignores both the sync `excludes` and the codebase `includes`. Every script of the codebase stores that digest in its `codebase` field, so any change to it marks all of them as edited.

## Suggestion

The CLI already runs esbuild per entry with `metafile: true` and reads `out.metafile.inputs` in `uncoveredBundleInputs`. Hashing the content of those inputs (plus the codebase config) gives a per-script digest with no extra build step. A script then re-pushes only when a file it bundles changes.

## Impact

Our workspace has one codebase with 542 bundled scripts: median bundle 8.9 MB, max 58 MB, 6.0 GiB total. Any edit, even a comment in a test file, re-pushes all 542 scripts in about 315 s and uploads 6 GiB. Old bundles stay in the object store until the storage lifecycle removes them.
