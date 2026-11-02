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

The script uses the `admins` workspace and the superadmin token. Each step edits one file, runs `wmill sync push`, and compares the scripts whose deployed hash changed with the scripts expected to change.

| Step | Edit | Expected redeploys | Actual redeploys | Bundles stored |
|---|---|---|---|---|
| 1 | first push | a, b, c | a, b, c | 3 |
| 2 | none | none | none | 3 |
| 3 | comment in `f/app/a.spec.ts` | none: no script bundles it | a, b, c | 6 |
| 4 | `f/app/lib/greet.ts` | a: only script bundling it | a, b, c | 9 |

"Bundles stored" counts objects under `script_bundle/` in MinIO. Each redeploy uploads a new bundle and keeps the old one, so it shows the upload and storage cost. At our scale, every push adds 6 GiB.

## Cause

`listSyncCodebases` in `cli/src/utils/codebase.ts` computes one digest per codebase: `digestDir(codebase.relative_path, JSON.stringify(codebase))` plus `extra_digest_paths`. `digestDir` hashes every file in the tree and ignores both the sync `excludes` and the codebase `includes`. Every script of the codebase stores that digest in its `codebase` field, so any change to it marks all of them as edited.

## Suggestion

The CLI already runs esbuild per entry with `metafile: true` and reads `out.metafile.inputs` in `uncoveredBundleInputs`. Hashing the content of those inputs (plus the codebase config) gives a per-script digest, so a script re-pushes only when a file it bundles changes. The trade-off: the esbuild pass moves before change detection, so `sync push` bundles every script locally even when nothing changed.

## Impact

Our workspace has one codebase with 542 bundled scripts: median bundle 8.9 MB, max 58 MB, 6.0 GiB total. Any edit, even a comment in a test file, re-pushes all 542 scripts in about 315 s and uploads 6 GiB. Old bundles stay in the object store until the storage lifecycle removes them.
