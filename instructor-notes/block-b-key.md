# Block B — instructor answer key

> **Don't read this before attempting the You-do.** Block B is mostly mechanical — the interesting content is in the failure-case discussion.

## What success looks like

By the end of Block B, the participant has:

1. The bundled `github-runner` container online — visible in their fork's *Settings → Actions → Runners* as `self-hosted, lab04`.
2. Two GitHub environments configured (`lab-gateway-dev`, `lab-gateway-prod`), each with `IGNITION_API_KEY` set as an environment-scoped secret.
3. Edited `projects/sample/com.inductiveautomation.perspective/views/Hello/view.json` in a PR, watched CI pass on `ubuntu-latest`, merged to main. (The sample project must be committed first — the I-do leaves it untracked.)
4. Watched `deploy.yml` run end-to-end on their bundled runner: checkout → verify prereqs → prune → ship (docker cp) → scan → smoke-check.
5. Verified the change in the **dev** gateway UI (http://localhost:8089).
6. Pushed a `v*` tag and watched `release.yml` promote the same change to **prod** (http://localhost:8090).
7. Deliberately broken at least one deploy and read the failure mode.

If any of these is missing, especially #7, push them to complete. The failure cases are half the lesson.

## The five-step pattern, walked through

Use this on the board if students need a re-walk:

1. **Commit:** developer edits `projects/sample/com.inductiveautomation.perspective/views/Hello/view.json`, commits, pushes a PR. PR merges to main.
2. **Checkout:** the bundled runner picks up the workflow, checks out the merged commit.
3. **Prune:** the runner reads `.deployignore` and removes those files from the working tree before they can ship.
4. **Ship:** `docker exec` wipes the target's `projects/` and `config/` dirs, then `docker cp` writes the working tree into the dev gateway's container.
5. **Scan:** `scripts/trigger-scan.sh both` posts to `/data/api/v1/scan/{projects,config}` against the dev gateway. Gateway re-reads disk.

## The shipped `deploy.yml`, annotated

```yaml
on:
  push:
    branches: [main]                # deploy only on merged PRs (or direct main pushes)
    paths:                          # skip workflow on docs-only changes
      - "projects/**"
      - "services/config/**"
      - ".deployignore"
      - "scripts/trigger-scan.sh"
  workflow_dispatch:                # let humans trigger manually for testing

permissions:
  contents: read                    # least privilege — no write, no PR comments

concurrency:
  group: deploy-lab-gateway-dev
  cancel-in-progress: false         # never let two deploys run at once

jobs:
  deploy:
    runs-on: [self-hosted, lab04]   # routes to the bundled runner
    environment: lab-gateway-dev    # secrets/vars scoped here
    env:
      IGNITION_URL: ${{ vars.IGNITION_URL || 'http://ignition-dev:8088' }}
      IGNITION_CONTAINER: ${{ vars.IGNITION_CONTAINER || 'lab04-ignition-dev' }}
      IGNITION_API_KEY: ${{ secrets.IGNITION_API_KEY }}
      GATEWAY_DATA_PATH: /usr/local/bin/ignition/data
    steps:
      - uses: actions/checkout@v4
      - name: Verify deploy prerequisites
        run: |                       # fail fast — docker present, API key set, target container running
          ...
      - name: Prune working tree per .deployignore
        run: |                       # in-runner-checkout `rm -rf` for matched paths/names
          ...
      - name: Ship projects and config into gateway container
        run: |                       # wipe-then-copy preserves "deleted in repo → deleted in gateway"
          docker exec "$IGNITION_CONTAINER" sh -c "rm -rf $GATEWAY_DATA_PATH/projects/* $GATEWAY_DATA_PATH/config/*"
          docker cp ./projects/.        "$IGNITION_CONTAINER:$GATEWAY_DATA_PATH/projects/"
          docker cp ./services/config/. "$IGNITION_CONTAINER:$GATEWAY_DATA_PATH/config/"
      - name: Trigger gateway scan
        run: scripts/trigger-scan.sh both
      - name: Smoke-check gateway health
        run: |                       # poll /StatusPing for 20s post-deploy
          ...
```

Things to highlight in the grade:

- **Least-privilege permissions.** Default `GITHUB_TOKEN` perms are too broad. `contents: read` is enough.
- **`paths:` filter.** Without this, every README change retriggers the deploy. With it, docs-only changes don't.
- **`concurrency` block.** Without this, two pushes in quick succession could deploy out of order. `cancel-in-progress: false` says: queue the new run, don't cancel the in-flight one. Cancellation mid-`docker cp` would leave the gateway in a partial state.
- **`environment:` scoping.** Secrets and variables are scoped to `lab-gateway-dev`. If a participant sets `IGNITION_API_KEY` at the repo level, it won't be picked up — and that's deliberate. Environments give you per-target secrets and deploy history "for free."
- **Verify step.** Cheap; catches the most common failures (missing API key, target container not running) before any file moves.
- **Smoke-check post-deploy.** The deploy can succeed but break the gateway. A 20s health-check window catches this.

`release.yml` is structurally the same — different trigger (`tags: ['v*']`), different environment (`lab-gateway-prod`), default URL pointing at `ignition-prod`. Same five steps.

## Common stumbles

- **"My runner isn't picking up jobs."** Three checks: container running (`docker compose ps github-runner`), `RUNNER_REPO_URL` points at the **fork**, `RUNNER_GITHUB_PAT` is a real PAT (not the placeholder). `docker compose logs github-runner` usually surfaces the issue immediately.
- **"The deploy ran but my change isn't visible in the gateway."** Walk them through: did the `Ship` step actually succeed (look at the docker cp output)? Did the scan return HTTP 200 (look at `trigger-scan.sh` output — it pretty-prints the response with `lastScanTimestamp`)? Are they looking at the **dev** gateway (8089) or the **local** gateway (8088)?
- **"The deploy 403'd on the scan step."** API key on the `lab-gateway-dev` environment doesn't have the right role. Needs Project Scan + Config Scan permissions. Easy to skip on creation.
- **"My PR has `Context access might be invalid` warnings."** Cosmetic IDE warnings — the GitHub Actions VS Code extension flags `vars.X` / `secrets.X` references that it can't verify because the environment doesn't exist yet on GitHub. Goes away once the environment is created.
- **"My `.deployignore` patterns aren't working."** The lab's prune logic handles literal paths (with a `/`) and bare-name globs (matched anywhere in the tree). It does NOT handle full gitignore semantics like `!` negations or `**/` deep globs. Keep patterns simple. If they need more, switch to `rsync --exclude-from` in the workflow.

## Failure-case discussion (Part 5)

This is the most teaching-rich segment. For each failure cause, walk through:

### `IGNITION_API_KEY` wrong on the environment

- **Symptom:** Ship step succeeds (docker cp doesn't care about the API). Scan step 403s. `trigger-scan.sh` pretty-prints the error response and the workflow exits non-zero.
- **State at the gateway:** New files are *on disk inside the container* but the gateway hasn't been told. Designer might still pick them up on next open; runtime is *stale*.
- **Recovery:** Update the environment secret, re-run the workflow (manual `workflow_dispatch`). The steps are idempotent.
- **Lesson:** Make the verify step fail fast. The shipped workflow checks `IGNITION_API_KEY` is non-empty; it can't validate the key's permissions without making a call, so the scan step is where you find out.

### Target container not running

- **Symptom:** Verify step fails with "container '<name>' is in state 'exited', expected 'running'". Deploy is a no-op.
- **State at the gateway:** Unchanged. Safe.
- **Recovery:** `docker compose up -d ignition-dev`. Re-run.
- **Lesson:** Fail fast at the right step. A late check is much worse — `docker cp` against a stopped container actually still writes to the volume, which then desyncs from the container's view of its filesystem on next start.

### Runner offline

- **Symptom:** Workflow queues forever ("waiting for a self-hosted runner..."). No logs because nothing's executing.
- **State at the gateway:** Unchanged.
- **Recovery:** `docker compose restart github-runner`. Workflow picks up automatically once the runner re-registers.
- **Lesson:** Self-hosted comes with operational cost. The lab makes this cheap (it's in compose) but a real customer setup has to keep the runner alive across reboots, PAT expirations, etc.

### Partial ship (runner killed mid-`docker cp`)

- **Symptom:** Some files are new, some are missing entirely. Gateway sees inconsistent state on scan.
- **State at the gateway:** Possibly broken — a view might reference a script that hasn't landed yet.
- **Recovery:** Re-run the workflow. The wipe-then-cp is destructive on each run, so it converges on the working tree's state.
- **Lesson:** This is the strongest argument for image-based deploys (atomic) when the failure mode matters. Most file-based deploys accept this risk because it's rare and recoverable.

## Rollback discussion

The shipped lab doesn't formally implement rollback — Block B intentionally leaves this open. Three patterns to mention:

1. **`git revert` + re-merge.** Idempotent; works for most cases.
2. **`release.yml` workflow_dispatch with an older tag.** This is the canonical "redeploy v0.1.0" pattern. Quick way to roll back prod without touching git history.
3. **Snapshot before deploy.** Take a `gwbk` before deploying. Lab-07 covers gateway backups properly.

If a participant asks *"what if the new view is bad and we need to revert *now*?"*, the answer for dev is option 1; for prod, option 2 is faster.

## Stretch — gateway-level config

A participant who completes the stretch should have noticed two distinct things:

1. **What ships:** the workflows `docker cp ./projects/.` and `./services/config/.` — so project content and the `config/resources/` tree ride along. But `services/modules.json` is a **sibling of** `services/config/`, *not under it*, so it is **not shipped** by the deploy workflows at all (it's bind-mounted into the gateways in this lab). Confirm via the `docker cp` targets in `deploy.yml`.
2. **What a scan can apply:** even setting aside shipping, module enable/disable can't be hot-reloaded —
   - Database connection JSON files: scan-friendly. New connection visible in the UI after scan.
   - `modules.json` (module enablement): needs a gateway restart. The scan API can't reload module state.

The payoff question (foreshadows Lab 05): file-based + scan is great for the things that change daily (views, connections) but can't touch the gateway/module baseline — which is exactly what image-based deploys own.

If they ask "how would I script the restart?" — `docker compose restart ignition-dev` from the runner, but that takes ~60s and breaks the smoke-check window. Real customer deploys handle this with a longer drain/restart cycle. Out of scope for Block B.

## Wrap-up — set up Day 4

Before students leave Block B:

- Have them stop the **runner container only** if they're not continuing right away (`docker compose stop github-runner`). The PAT will be in `.env` until they `git clean` or rotate it.
- Remind them lab-04-image-based is the natural continuation — same Ignition stack, different deploy mechanism.
- Foreshadow: "Tomorrow we move from one logical gateway to many. The deploy you just built scales by repeating; the question is how to coordinate."
