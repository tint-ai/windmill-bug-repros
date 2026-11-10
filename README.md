# A dedicated flow never uses its runners for `type: script` steps

Minimal repro: a flow flagged `dedicated_worker: true` starts one runner per step, but a step that references a workspace script by path never reaches its runner. Each run of that step spawns a fresh `bun run`. Inline (`rawscript`) steps of the same flow do run on their runner.

Tested on Windmill EE 1.847.0, Bun scripts. The dispatch code quoted below is unchanged in 1.855.1 and on `main`.

## Layout

```
docker-compose.yml   # Postgres, Windmill EE server, a default worker, a worker in group `dedicated`
repro.sh             # the steps below
f/echo.ts            # script f/r/echo: returns x + 1, after a 500 ms top-level delay
f/flow.json          # flow f/r/flow, dedicated_worker: true
                     #   a: type script, path f/r/echo
                     #   b: type script, path f/r/echo
                     #   c: type rawscript, same code as f/echo.ts
```

The 500 ms top-level `await` in the script stands in for module load time (large imports). A warm runner pays it once at startup. A fresh `bun run` pays it on every job, so the dispatch path shows up in `duration_ms`.

## Steps

```sh
WM_LICENSE_KEY=<ee-license> ./repro.sh   # WM_PORT defaults to 48200
docker compose down -v                   # clean up
```

`repro.sh` uses the `admins` workspace and the superadmin token. It:

1. Creates script `f/r/echo` and flow `f/r/flow` with `dedicated_worker: true` through the API.
2. Reads the flow's tag from its `flowdependencies` job: `admins:flow/f/r/flow`.
3. Sets worker group `dedicated` to `{"dedicated_workers":["admins:flow/f/r/flow"],"worker_tags":["admins:flow/f/r/flow"]}` and waits for the worker to restart with its runners.
4. Runs the flow 5 times and prints, for each step job, the worker group that pulled it, `duration_ms`, and how the worker log shows it was run.
5. Adds `admins:f/r/echo` to `dedicated_workers` (the workaround), waits for the restart, and runs the flow 5 more times.

"Dispatch" is read from the dedicated worker log, matched by job id: `runner (<path>)` for `received job and adding to queue on dedicated worker for <path>: <job id>`, `bun run` for `child process 'bun run' took Nms job_id=<job id>`.

## Actual

Total runtime: about 55 s from a clean `down -v` (images already pulled).

With the flow entry only, the worker registers one runner per step, and starts a runner process for `f/r/echo`:

```
windmill-worker/src/dedicated_worker_ee.rs:845: spawned dedicated worker for flow: admins:f/r/flow/a
windmill-worker/src/dedicated_worker_ee.rs:845: spawned dedicated worker for flow: admins:f/r/flow/b
windmill-worker/src/dedicated_worker_ee.rs:845: spawned dedicated worker for flow: admins:f/r/flow/c
windmill-worker/src/dedicated_worker_ee.rs:214: dedicated worker process started f/r/flow/c
windmill-worker/src/dedicated_worker_ee.rs:214: dedicated worker process started f/r/echo
```

Every step job is pulled by the dedicated worker. Steps `a` and `b` still spawn `bun run` and pay the 500 ms on each run; step `c` hits its runner:

```
run  step  runnable_path  worker     duration_ms  dispatch
1    a     f/r/echo       dedicated  530          bun run (took 508ms)
1    b     f/r/echo       dedicated  529          bun run (took 510ms)
1    c     f/r/flow/c     dedicated  23           runner (f/r/flow/c)
2    a     f/r/echo       dedicated  530          bun run (took 511ms)
2    b     f/r/echo       dedicated  535          bun run (took 514ms)
2    c     f/r/flow/c     dedicated  24           runner (f/r/flow/c)
3    a     f/r/echo       dedicated  525          bun run (took 508ms)
3    b     f/r/echo       dedicated  520          bun run (took 515ms)
3    c     f/r/flow/c     dedicated  4            runner (f/r/flow/c)
4    a     f/r/echo       dedicated  528          bun run (took 509ms)
4    b     f/r/echo       dedicated  537          bun run (took 516ms)
4    c     f/r/flow/c     dedicated  17           runner (f/r/flow/c)
5    a     f/r/echo       dedicated  529          bun run (took 511ms)
5    b     f/r/echo       dedicated  533          bun run (took 513ms)
5    c     f/r/flow/c     dedicated  20           runner (f/r/flow/c)

Dispatch lines in the dedicated worker log for these runs:
  'on dedicated worker for f/r/echo:'   0
  'on dedicated worker for f/r/flow/c:' 5
  'child process 'bun run' took'        10
```

Typical log line for steps `a` and `b`:

```
INFO job:run_subprocess: windmill-worker/src/handle_child.rs:476: child process 'bun run' took 512ms job_id=01a1c645-43e1-d410-9f93-ea4d274f2ddf success=true ...
```

With the workaround (`admins:f/r/echo` added), all three steps run on a runner:

```
{"dedicated_workers":["admins:flow/f/r/flow","admins:f/r/echo"],"worker_tags":["admins:flow/f/r/flow"]}
windmill-worker/src/dedicated_worker_ee.rs:845: spawned dedicated worker for flow: admins:f/r/flow/a
windmill-worker/src/dedicated_worker_ee.rs:845: spawned dedicated worker for flow: admins:f/r/flow/b
windmill-worker/src/dedicated_worker_ee.rs:845: spawned dedicated worker for flow: admins:f/r/flow/c
windmill-worker/src/dedicated_worker_ee.rs:214: dedicated worker process started f/r/flow/c
windmill-worker/src/dedicated_worker_ee.rs:214: dedicated worker process started f/r/echo
windmill-worker/src/dedicated_worker_ee.rs:214: dedicated worker process started f/r/echo

run  step  runnable_path  worker     duration_ms  dispatch
1    a     f/r/echo       dedicated  6            runner (f/r/echo)
1    b     f/r/echo       dedicated  4            runner (f/r/echo)
1    c     f/r/flow/c     dedicated  13           runner (f/r/flow/c)
2    a     f/r/echo       dedicated  5            runner (f/r/echo)
2    b     f/r/echo       dedicated  4            runner (f/r/echo)
2    c     f/r/flow/c     dedicated  3            runner (f/r/flow/c)
3    a     f/r/echo       dedicated  5            runner (f/r/echo)
3    b     f/r/echo       dedicated  3            runner (f/r/echo)
3    c     f/r/flow/c     dedicated  4            runner (f/r/flow/c)
4    a     f/r/echo       dedicated  3            runner (f/r/echo)
4    b     f/r/echo       dedicated  6            runner (f/r/echo)
4    c     f/r/flow/c     dedicated  4            runner (f/r/flow/c)
5    a     f/r/echo       dedicated  4            runner (f/r/echo)
5    b     f/r/echo       dedicated  5            runner (f/r/echo)
5    c     f/r/flow/c     dedicated  3            runner (f/r/flow/c)

Dispatch lines in the dedicated worker log for these runs:
  'on dedicated worker for f/r/echo:'   10
  'on dedicated worker for f/r/flow/c:' 5
  'child process 'bun run' took'        0
```

Steps `a` and `b` go through the runner registered for the script entry. The `f/r/echo` process started for the flow's own steps (`admins:f/r/flow/a`, `/b`) still receives no job: two `f/r/echo` processes run, and one stays idle.

## Expected

With the flow entry only, steps `a` and `b` run on the runners registered as `admins:f/r/flow/a` and `admins:f/r/flow/b`, like step `c` does on `admins:f/r/flow/c`. No `bun run` per step, and no need to list the step scripts in the worker group.

## Cause

`backend/windmill-worker/src/worker.rs` at v1.847.0, lines 3917-3931, picks the runner from `job.runnable_path`:

```rust
if !dedicated_workers.is_empty() && !fails_before_running && !restricted {
    let dedicated_worker_tx = job.runnable_path.as_ref().and_then(|path| {
        let key =
            if let Some(flow_root) = crate::common::extract_flow_root(path) {
                let step_id = job.flow_step_id.as_deref().unwrap_or("");
                format!("{}:{}/{}", job.workspace_id, flow_root, step_id)
            } else {
                format!("{}:{}", job.workspace_id, path)
            };
        dedicated_workers.get(&key)
    });
```

- For an inline step, `runnable_path` is `f/r/flow/c`, so the key `admins:f/r/flow/c` matches the runner registered for the step.
- For a `type: script` step, `runnable_path` is the script's own path, `f/r/echo`. `extract_flow_root` only matches branch/loop segments (`common.rs:2128`), so the key is `admins:f/r/echo`. The runners are registered as `admins:f/r/flow/a` and `admins:f/r/flow/b`, so the lookup misses and the job falls through to the regular `bun run` path.

The step job carries `flow_step_id` (`a`, `b`) and its parent flow path is known, so the key `<workspace>:<flow path>/<step id>` could be built for script steps too, for example from the root job's `runnable_path` and `flow_step_id`.

## Workaround

List every script referenced by the flow's steps in the group's `dedicated_workers` as `<workspace>:<script path>`, next to the flow entry. The worker then starts an extra runner per script, and the step jobs (tagged with the flow's tag) match it by `runnable_path`. The runners started for the flow's script steps stay unused.
