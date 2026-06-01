# Block B — File-based deploy mechanic

**Duration:** ~90 minutes
* 20 min demo
* 20 min we-do
* 40 min you-do
* 10 min debrief

## Goal

You should leave this block able to:

- Describe the file-based deploy pattern in five steps: **checkout → prune → ship → scan → verify**
- Run a deploy manually against the local gateway and watch it pick up the change
- Wire the same flow into the bundled GitHub Actions self-hosted runner so a PR merge promotes a change from **local** → **dev**, and a tag push promotes it to **prod**
- Read [`.deployignore`](../.deployignore) and explain why each pattern is in there

## Pre-flight

```bash
scripts/setup.sh    # idempotent — safe even if the stack is already up
```

You'll need:

- **A fork of this repo on GitHub.** The bundled runner registers against your fork, not the upstream.
- **A GitHub Personal Access Token with `repo` scope.** Put it in `.env` as `RUNNER_GITHUB_PAT`. The bundled `github-runner` container in `docker-compose.yaml` uses it to auto-register itself — no manual `docker run`, no registration tokens to copy.
- **An Ignition API key per gateway you want to scan.** Generate each in the gateway UI: *Config → Security → API Keys → New*. Scope it to `Project Scan` and `Config Scan`. Copy the value once — you can't read it back. Drop them into `.env` as `IGNITION_API_KEY_LOCAL` / `_DEV` / `_PROD`.
- **GitHub Environments** for the deploy workflows. `lab-gateway-dev` for `deploy.yml`, `lab-gateway-prod` for `release.yml`. Each needs a secret `IGNITION_API_KEY` (the value from the matching gateway). Defaults for the URL + container variables are already what the bundled runner expects, so you usually don't need to set them.

If you'd like to read ahead: [`docs/file-based-deploy-pattern.md`](../docs/file-based-deploy-pattern.md).

## I do (20 min)

The file-based pattern, demoed end-to-end across the three lab gateways.

The five steps:

1. **Developer commits** to `projects/<name>/` in git.
2. **Runner checks out** the merged commit. The bundled `github-runner` container handles this.
3. **Runner prunes** the working tree per `.deployignore` so lab-only files (READMEs, docs, scripts) don't pollute the gateway.
4. **Runner ships** the files into the target gateway container via `docker cp` (dev and prod use named volumes — no shared filesystem with the runner).
5. **Runner calls** `POST /data/api/v1/scan/{projects,config}` to make the gateway notice the change without a restart.

Live demo:

```bash
# Add a tiny project on disk (simulating what a developer commit would produce).
# Because `local` bind-mounts ./projects/, these files are already on the local
# gateway's disk before we do anything else. Note the 8.3 module-namespaced path
# and the required resource.json manifest.
VIEW="projects/sample/com.inductiveautomation.perspective/views/Hello"
mkdir -p "$VIEW"
cat > projects/sample/project.json <<'EOF'
{"title":"Sample","description":"Demo from Block B","enabled":true,"inheritable":false,"parent":""}
EOF
cat > "$VIEW/view.json" <<'EOF'
{"custom":{},"params":{},"props":{"defaultSize":{"height":600,"width":800}},
 "root":{"type":"ia.container.coord","version":0}}
EOF
cat > "$VIEW/resource.json" <<'EOF'
{"scope":"G","version":1,"restricted":false,"overridable":true,"files":["view.json"],"attributes":{}}
EOF

# Trigger a project scan on the local gateway:
scripts/trigger-scan.sh projects --gateway local
```

In the local gateway UI (http://localhost:8088), the `sample` project should now appear in the project list (Config → Projects, or the Perspective project launcher).

Sketch the *runner topology* on the board:

```
       ┌─────────────┐                ┌────────────────────────────────┐
       │  GitHub     │ ── polls ──▶   │  bundled runner (lab04-runner) │
       │  Actions    │                │   • shares /var/run/docker.sock│
       │             │ ◀── results ── │   • on the lab's compose net   │
       └─────────────┘                └────────────────────────────────┘
                                                  │
                                                  │ docker cp / docker exec
                                                  ▼
                                       ┌──────────────────────┐
                                       │ ignition-dev (named) │
                                       │ ignition-prod (named)│
                                       └──────────────────────┘
```

The runner doesn't share a bind-mounted filesystem with dev/prod — they each have a named volume. The runner reaches *inside* the container with `docker cp` instead. (Local is different: it bind-mounts `./projects/` and `./services/config/` from the repo, so changes show up there without any copy step.)

## We do (20 min)

Together, do the deploy manually using the shipped scripts. We'll target all three gateways one at a time.

1. Set up your shell env once:
   ```bash
   # The trigger-scan script will read IGNITION_API_KEY_LOCAL/_DEV/_PROD from .env,
   # so as long as those are filled in you don't need to export anything.
   ```
2. Change `projects/sample/com.inductiveautomation.perspective/views/Hello/view.json` (e.g., `width: 800` → `width: 1200`).
3. Scan the **local** gateway — local sees the change via bind mount immediately, scan tells it to notice:
   ```bash
   scripts/trigger-scan.sh both --gateway local
   ```
   Verify in http://localhost:8088 — the view's width should match.
4. Now copy the same change to **dev** manually (this is what `deploy.yml` will automate in a moment):
   ```bash
   docker exec lab04-ignition-dev sh -c \
     "rm -rf /usr/local/bin/ignition/data/projects/* /usr/local/bin/ignition/data/config/*"
   docker cp ./projects/.        lab04-ignition-dev:/usr/local/bin/ignition/data/projects/
   docker cp ./services/config/. lab04-ignition-dev:/usr/local/bin/ignition/data/config/
   scripts/trigger-scan.sh both --gateway dev
   ```
   Verify in http://localhost:8089 — the same view should appear, the same width.
5. Inspect `.deployignore`. Notice it excludes `README.md`, `LICENSE`, the `.github/` directory, `docs/`, `exercises/`, `scripts/`, etc. Why? Because the gateway shouldn't care about lab documentation or tooling — only project and config content belongs on it.

## You do (40 min)

Wire the same flow into GitHub Actions, then watch a real PR ride through to dev and a tag push ride through to prod.

### Part 1 — Verify the runner is up (5 min)

The runner is already running as part of the compose stack. Confirm it:

```bash
docker compose ps github-runner
docker compose logs --tail 50 github-runner   # look for "Listening for Jobs"
```

In your fork on GitHub, *Settings → Actions → Runners* should show the runner online with the `self-hosted, lab04` labels. If it's not there:

- `RUNNER_REPO_URL` in `.env` must point at your fork (not the upstream).
- `RUNNER_GITHUB_PAT` must be a real PAT with `repo` scope (the example placeholder won't work).
- Restart it: `docker compose restart github-runner`.

### Part 2 — GitHub environments + secrets (10 min)

In your fork:

1. *Settings → Environments → New environment*: `lab-gateway-dev`.
2. Under that environment, *Add secret*: `IGNITION_API_KEY` = the API key you generated **on the dev gateway** (its UI is at http://localhost:8089). (The workflow reads `secrets.IGNITION_API_KEY` scoped to the environment.)
3. Repeat for `lab-gateway-prod` with the API key generated **on the prod gateway** (http://localhost:8090).

> **API keys are per-gateway, not per-URL.** You generate each key in *that gateway's* UI; the dev key won't authenticate against prod. The host ports (8089/8090) are just how *you* reach the UIs — the **runner** reaches the same gateways by their compose service names (`http://ignition-dev:8088`, `http://ignition-prod:8088`), which is why `IGNITION_URL`'s default differs from the host port.

You **don't** need to set `IGNITION_URL` or `IGNITION_CONTAINER` variables unless your runner topology differs from the lab's — the workflow defaults match the bundled runner.

### Part 3 — Trigger `deploy.yml` (15 min)

> **Prerequisite:** Part 3's PR needs the `sample` project to be *committed*. The I-do/We-do created it on disk but left it untracked, so commit it first:
> ```bash
> git add projects/sample && git commit -m "Add sample project"
> ```
> No `sample` project (e.g. you skipped the demo)? Touch any view under the shipped `projects/example-project/` instead — the flow is identical.

1. Open a PR that touches `projects/sample/com.inductiveautomation.perspective/views/Hello/view.json` — change the height value.
2. Watch [`ci.yml`](../.github/workflows/ci.yml) run on the PR. It runs on `ubuntu-latest` (free, no self-hosted needed), validates JSON, `.deployignore`, and the workflow files themselves.
3. Merge the PR to `main`. [`deploy.yml`](../.github/workflows/deploy.yml) fires because of the `paths:` filter.
4. Watch the workflow run. The interesting step is **Ship projects and config into gateway container** — this is the `docker cp` half. Then **Trigger gateway scan** posts to `/data/api/v1/scan/{projects,config}`.
5. Verify in http://localhost:8089 — the view's height should match what you pushed.

### Part 4 — Trigger `release.yml` (10 min)

Same files, different trigger: a tag push promotes from dev to prod.

```bash
git checkout main
git pull
git tag v0.1.0
git push origin v0.1.0
```

[`release.yml`](../.github/workflows/release.yml) fires on the tag. Watch it run, then check http://localhost:8090 — the change you merged earlier (and just released) should be visible on the prod gateway.

### Part 5 — Failure cases (optional, ~5 min)

Cause one of these on purpose and read the workflow output:

- Set the wrong API key in `lab-gateway-dev`'s environment secret → scan step 403s. Files made it into the container, but the gateway didn't reload. *What's your recovery story?*
- Stop the dev container (`docker compose stop ignition-dev`) and trigger a deploy → the pre-flight step fails with "container is in state 'exited', expected 'running'". Better than failing halfway through.

End state matches `block-b-end`.

## Definition of done

You're finished with Block B when:

- [ ] The bundled runner shows **online** in your fork (*Settings → Actions → Runners*, `self-hosted, lab04`).
- [ ] Both GitHub environments (`lab-gateway-dev`, `lab-gateway-prod`) exist, each with an `IGNITION_API_KEY` secret.
- [ ] A merged PR triggered `deploy.yml` and the change is visible on the **dev** gateway (:8089).
- [ ] A `v*` tag triggered `release.yml` and the change is visible on the **prod** gateway (:8090).
- [ ] You broke **one** deploy on purpose (Part 5) and can describe the failure mode and recovery.
- [ ] You can explain, in five steps, what the runner does between "PR merged" and "gateway reloaded."

## Stretch challenge `[OPTIONAL]`

Notice that **gateway-level config** (the contents of `services/config/`) ships the same way `projects/` does — both workflows `docker cp ./services/config/.` onto the gateway. But not every gateway change rides that path, and not every change a scan can apply:

- **Module enablement** lives in `services/modules.json` — a *sibling* of `services/config/`, **not under it**. The deploy workflows copy `./services/config/.`, so `modules.json` is **not shipped** by them at all; in this lab it's bind-mounted into all three gateways. Open `deploy.yml` and confirm the `docker cp` targets to see this.
- Even if you did get a new `modules.json` onto a gateway, **a scan won't apply it** — module enable/disable needs a gateway **restart** (`docker compose restart ignition-dev`), unlike views/config which hot-reload on scan.

So the question to chew on: why does the file-based scan pattern work beautifully for views and database connections but not for modules? What does that tell you about where the image-based deploy (Lab 05) earns its keep?

## Debrief (10 min)

- What happens if the runner crashes mid-deploy? The `docker cp` is *not* atomic — the gateway could see a partial filesystem. What does the gateway do if a project is partially copied?
- What's the rollback story? (Hint: `git revert` + re-deploy is one option. `release.yml` accepts a `workflow_dispatch` with a tag input — what does that buy you?)
- Where does `.deployignore` matter most? When *would* you want lab-only files on the gateway?
- For your customer's real gateway: where would the self-hosted runner sit on the network? What does it need access to that GitHub-hosted runners don't have?
