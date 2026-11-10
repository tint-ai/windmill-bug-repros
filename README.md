# An error thrown on a dedicated Bun runner loses `step_id`, `flow_path`, `job_id` and `extra`

Minimal repro: when a Bun script throws on a dedicated runner, the job's `result.error` holds only `message`, `name`, `stack` and `line`. The same script on a regular worker also gets `job_id`, `extra` (custom properties of the thrown error) and, inside a flow, `step_id` and `flow_path`. A flow `failure_module` that reads `error.step_id` or `error.extra` gets nothing once the flow runs on dedicated runners.

Tested on Windmill EE 1.847.0, Bun scripts. The dedicated-runner wrapper quoted below is unchanged in 1.855.1 and on `main`.

## Layout

```
docker-compose.yml   # Postgres, Windmill EE server, a default worker, a worker in group `dedicated`
repro.sh             # the steps below
f/boom.ts            # throws Object.assign(new Error("boom"), { metadata: { code: "SOME_CODE" } })
f/flow.json          # flow template: step `a` (type script, by path) + an inline failure_module
                     # that returns { keys: Object.keys(error).sort(), step_id, extra }
```

`repro.sh` deploys `f/boom.ts` twice and the flow twice:

| Runnable | `dedicated_worker` | Step `a` |
|---|---|---|
| script `f/r/boom` | false | |
| script `f/r/boom_ded` | true | |
| flow `f/r/flow` | false | `f/r/boom` |
| flow `f/r/flow_ded` | true | `f/r/boom_ded` |

Worker group `dedicated` lists both `admins:f/r/boom_ded` and `admins:flow/f/r/flow_ded`. The script entry is needed for step `a` to reach a runner at all: a dedicated flow does not dispatch `type: script` steps to the runners it starts for them (separate issue, see branch `dedicated-flow-skips-runners-for-script-steps`).

## Steps

```sh
WM_LICENSE_KEY=<ee-license> ./repro.sh   # WM_PORT defaults to 48300
docker compose down -v                   # clean up
```

`repro.sh` uses the `admins` workspace and the superadmin token. It deploys the four runnables, configures the worker group, waits for the dedicated worker to restart with its runners, then runs each runnable once and prints what it got.

## Actual

Total runtime: about 35 s from a clean `down -v` (images already pulled).

```
================ 1. script f/r/boom, default worker
worker: wk-default-42197c760147-2O8g3
result: {"error": {"name": "Error", "extra": {"metadata": {"code": "SOME_CODE"}}, "stack": "Error: boom\n    at main (/tmp/windmill/cache/bun/91418aef04c22cc92114b86f7c61742093548c48a5eb45b8f320c5ab221068ca:4:28)\n    at run (/tmp/windmill/wk-default-42197c760147-2O8g3/01a1c64a-fe69-cac4-1915-e6177e4c0d6c/wrapper.mjs:30:21)\n    at /tmp/windmill/wk-default-42197c760147-2O8g3/01a1c64a-fe69-cac4-1915-e6177e4c0d6c/wrapper.mjs:42:11", "job_id": "01a1c64a-fe69-cac4-1915-e6177e4c0d6c", "message": "boom"}}
error keys: ["extra","job_id","message","name","stack"]

================ 2. script f/r/boom_ded, dedicated runner
worker: wk-dedicated-db7e5158218b-8usC4
result: {"error": {"line": "{}", "name": "Error", "stack": "Error: boom\n    at main (/tmp/windmill/wk-dedicated-db7e5158218b-8usC4/dedicated-admins__f__r__boom_ded/main.ts:2:27)\n    at /tmp/windmill/wk-dedicated-db7e5158218b-8usC4/dedicated-admins__f__r__boom_ded/wrapper.mjs:57:44", "message": "boom"}}
error keys: ["line","message","name","stack"]
windmill-worker/src/dedicated_worker_ee.rs:304: received job and adding to queue on dedicated worker for f/r/boom_ded: 01a1c64b-00d0-1903-fe72-02dcdd9dd049 (que

================ 3. flow f/r/flow, default worker
step job: a failure wk-default-42197c760147-2O8g3
step job: failure success wk-default-42197c760147-2O8g3
step a error keys: ["extra","flow_path","job_id","message","name","stack","step_id"]
failure module received: {"keys": ["extra", "flow_path", "job_id", "message", "name", "stack", "step_id"], "extra": {"metadata": {"code": "SOME_CODE"}}, "step_id": "a"}

================ 4. flow f/r/flow_ded, dedicated runners
step job: a failure wk-dedicated-db7e5158218b-8usC4
step job: failure success wk-dedicated-db7e5158218b-8usC4
step a error keys: ["line","message","name","stack"]
failure module received: {"keys": ["line", "message", "name", "stack"], "extra": null, "step_id": null}
windmill-worker/src/dedicated_worker_ee.rs:304: received job and adding to queue on dedicated worker for f/r/boom_ded: 01a1c64b-0a3b-f945-afc2-ade043b8f93e (que
job:run_subprocess: windmill-worker/src/handle_child.rs:476: child process 'bun run' took 13ms job_id=01a1c64b-0a55-b53f-d8ac-d5f247a481f7 success=true mem_peak
```

In case 4, step `a` ran on the `f/r/boom_ded` runner, and the failure module ran as a regular `bun run` on the same worker. The worker registered a runner only for step `a` (`spawned dedicated worker for flow: admins:f/r/flow_ded/a`), none for the failure module.

The dedicated error also carries `line`, which is the job's raw arguments JSON (`"{}"` here).

## Expected

The error from a dedicated runner has the same shape as from a regular worker: `job_id`, `extra` with the thrown error's own properties, and inside a flow `step_id` and `flow_path`. In case 4 the failure module receives `step_id: "a"` and `extra: {"metadata": {"code": "SOME_CODE"}}`, as in case 3.

## Cause

`backend/windmill-worker/src/bun_executor.rs` at v1.847.0.

The regular wrapper (lines 2898-2925; the workflow-as-code wrapper at 2824-2851 does the same) builds the error like this:

```js
let err = { message: e.message, name: e.name, stack: e.stack };
let step_id = process.env.WM_FLOW_STEP_ID;
if (step_id) { err["step_id"] = step_id; }
let job_id = process.env.WM_JOB_ID;
if (job_id) { err["job_id"] = job_id; }
let flow_path = process.env.WM_FLOW_PATH;
if (flow_path) { err["flow_path"] = flow_path; }
const extra = {};
Object.getOwnPropertyNames(e).forEach((key) => {
    if (['line', 'name', 'stack', 'column', 'message', 'sourceURL', 'originalLine', 'originalColumn'].includes(key)) { return; }
    extra[key] = e[key];
});
if (Object.keys(extra).length > 0) { err["extra"] = extra; }
```

The dedicated-runner wrapper catches errors in four places (lines 273, 287, 321 and 347: `execd_preprocess:`, `execd:`, `exec_preprocess:`, `exec:`), each with:

```js
console.log("wm_res[error]:" + JSON.stringify({ message: e.message, name: e.name, stack: e.stack, line: argsJson }));
```

No `step_id`, `job_id`, `flow_path` or `extra`. The runner is a long-lived process, so `WM_FLOW_STEP_ID`, `WM_JOB_ID` and `WM_FLOW_PATH` from its environment would not be per job either; these values have to come from the worker with each job (for example on the `exec:` line) or be added by the worker when it reads `wm_res[error]`. `extra` only needs the same `Object.getOwnPropertyNames` loop in the four `catch` blocks.
