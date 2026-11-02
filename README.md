# `wmill sync push` never reaches "0 changes" on an unchanged tree

Minimal repro for two digest mismatches that make `wmill sync push` re-push the same scripts on every run, with no local edit.

Tested on Windmill EE server and CLI 1.847.0, Bun scripts.

## Layout

```
wmill.yaml                         # codebase: relative_path f/codebase (default cjs format)
f/codebase/multi_output.ts         # codebase script importing a .node file
f/codebase/native/addon.node       # dummy file, makes esbuild emit a 2nd output
f/plain/empty_schema.ts            # plain script, no arguments
f/plain/empty_schema.script.yaml   # metadata holds `schema: {}`
```

## Steps

Everything runs in Docker: Postgres, MinIO (codebase bundle store), the Windmill EE server, two workers, and the CLI (`bunx windmill-cli@1.847.0`).

```sh
WM_LICENSE_KEY=<ee-license> ./repro.sh
```

The script pushes the tree three times in a row with no edit, then prints the remote state of both scripts.

## Actual

Pushes #2 and #3 both report the same two changes:

```
remote (admins) <- local: 2 changes to apply
~ script f/codebase/multi_output.script.yaml (codebase changed)
~ script f/plain/empty_schema.script.yaml
...
Script f/codebase/multi_output is up to date
Updated script f/plain/empty_schema
```

Remote state after three pushes:

```
{"path":"f/codebase/multi_output","codebase":"9dff44e7…4014ce.tar", ...}
  versions: 1
{"path":"f/plain/empty_schema","schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":[],"properties":{}}}
  versions: 3
```

## Expected

Pushes #2 and #3 report `0 changes to apply`.

## Cause 1: multi-output bundles compare against a digest without `.tar`

esbuild's default loader in the CLI is `{ ".node": "file" }`, so importing a `.node` file emits a second output file. The CLI then pushes a tarball and stores the codebase digest with a `.tar` suffix.

- The push stores `codebase.getDigest(forceTar)`, with `forceTar = true` for a multi-output bundle (`esm/main.js:65392` and `:65426` in the npm package).
- The diff compares against `c.getDigest()`, with no argument (`esm/main.js:67926`, `addCodebaseDigestIfRelevant`, and `:69427`).

`getDigest()` appends `.tar` only when `forceTar` is set or the codebase declares `assets`. The local digest is `9dff…4014ce`, the remote one is `9dff…4014ce.tar`, and the script shows `(codebase changed)` on every push. The push step itself detects no change (`is up to date`), but only after re-bundling every such script.

Real-world trigger: `ssh2`, whose native crypto addon is a `.node` file.

## Cause 2: `schema: {}` never matches the stored schema

The local `.script.yaml` holds `schema: {}`. The remote stores the expanded empty object schema (`$schema`, `type: object`, `properties: {}`, `required: []`). The diff compares the parsed YAML with `deepEqual`, so the two never match.

Unlike cause 1, the push step also sees a difference and deploys a new script version on every push: `f/plain/empty_schema` has 3 versions after 3 pushes with no edit.

## Impact

About 45 of our `.script.yaml` files hit cause 2, plus every `ssh2`-based codebase script hits cause 1. A no-op `wmill sync push` takes 71 s in our workspace and creates a new version of each cause-2 script.
