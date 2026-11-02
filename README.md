# Codebase script loses its bundle after a lib push

Minimal repro for: the `dependencies` job triggered by a lib push redeploys codebase scripts without their bundle.

Tested on Windmill server and CLI 1.847.0 (EE), Bun scripts.

## Layout

```
wmill.yaml                    # codebase: relative_path f, format esm, includes app/**
f/app/hello.ts                # codebase script, bundled with esbuild
f/shared/lib/format.ts        # plain workspace script (no_main_func), imports dayjs
```

`f/app/hello.ts` imports `../shared/lib/format.ts` with a relative import, so the bundle inlines the lib.

## Steps

Everything runs in Docker: Postgres, Windmill EE server, a default worker, a dependency worker, and the `wmill` CLI (`bunx windmill-cli@1.847.0`).

```sh
LICENSE_KEY=<ee-license> ./repro.sh
```

The script uses the `admins` workspace and the superadmin token. It does:

1. `wmill sync push`: `f/app/hello` is deployed as an esm bundle and runs fine.
2. Edits `f/shared/lib/format.ts` only, then `wmill sync push` again.
3. The server runs a `dependencies` job on `f/app/hello` because it imports the lib. That job relocks the script and deploys a new version with a lock and no bundle.
4. `wmill script run f/app/hello` now fails:

```
execution error:
Failed to pull bytes from object store: script_bundle/<workspace>/<hash>.esm
```

## Expected

A script deployed as a codebase bundle already has its dependencies inside the bundle. The relock on lib change should either skip it, or carry the bundle over to the new version.

## Impact

In our workspace, a full push of 497 codebase scripts left 66 in this state. The only workaround is excluding `**/lib/**` from sync so no dependency job runs. That makes codebases all-or-nothing per workspace: bundled scripts and plain scripts can't share libs.
