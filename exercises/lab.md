# Lab 04 — The Ignition 8.3 file structure & a file-based deploy pipeline

**Duration:** ~3 hours, in two parts

1. **Decode the Ignition 8.3 file structure** (~90 min) — know every file in a gateway's `data/` directory: what it is, who owns it, whether it belongs in git.
2. **Build the file-based deploy** (~90 min) — wire that knowledge into GitHub Actions: a merge into `develop` ships to the dev gateway, a tag cut from `main` ships to prod. Hot scan, no restarts.

The second part automates exactly what you do by hand in the first. Do them in order.

## Goal

You should leave this lab able to:

- Navigate an Ignition 8.3 gateway's `data/` directory and name what each top-level item is for
- Explain the difference between **project-level**, **gateway-level**, and **operational** state, and decide which files belong in git
- Predict which files appear on disk when you make a given change in the gateway UI
- Describe the file-based deploy pattern in five steps: **checkout → prune → ship → scan → verify**
- Run a deploy manually, then wire the same flow into the bundled GitHub Actions self-hosted runner following **Git Flow**: a merge into `develop` promotes to **dev**, and a tag cut from `main` promotes to **prod**
- Read [`.deployignore`](../.deployignore) and explain why each pattern is in there

## Pre-flight

```bash
cp -n .env.example .env
scripts/setup.sh    # idempotent — brings up the stack and waits for all three gateways
# When it finishes:
curl -fsS http://localhost:8088/StatusPing
```

Open <http://localhost:8088> (the `local` gateway) in your browser. Login: `admin` / `password` (or whatever you set as `GATEWAY_ADMIN_PASSWORD_LOCAL` in `.env`). The dev and prod gateways (`:8089` / `:8090`) come up too but stay empty until the deploy part.

Before you start the deploy part, get these in place (they take a few minutes and the #1 "nothing deploys" cause is a missing `develop` branch):

- **A fork of this repo on GitHub, with Actions enabled.** The bundled runner registers against your fork, not the upstream. Forks ship with workflows **disabled** — open your fork's *Actions* tab and click "I understand my workflows, go ahead and enable them."
- **A `develop` branch in your fork.** Git Flow's integration branch. Create it once:
  ```bash
  git checkout -b develop && git push -u origin develop
  ```
  Optionally set it as the fork's **default branch** (*Settings → Branches*) so feature PRs target it by default.
- **The GitHub CLI (`gh`), installed and authenticated** (`gh auth login`), with `RUNNER_REPO_URL` in `.env` pointed at **your fork**. `setup.sh` mints the runner's short-lived registration token with `gh` and hands it to the bundled `github-runner` container — no Personal Access Token to create or store (same as Lab 03).
- **An Ignition API key per gateway you want to scan.** Generate each in the gateway UI: *Config → Security → API Keys → New*, scoped to `Project Scan` and `Config Scan`. Copy the value once — you can't read it back. Drop them into `.env` as `IGNITION_API_KEY_LOCAL` / `_DEV` / `_PROD`.
- **GitHub Environments** for the deploy workflows: `lab-gateway-dev` for `deploy.yml`, `lab-gateway-prod` for `release.yml`. Each needs a secret `IGNITION_API_KEY` (the value from the matching gateway).

Read-ahead: [`docs/ignition-file-structure.md`](../docs/ignition-file-structure.md) and [`docs/file-based-deploy-pattern.md`](../docs/file-based-deploy-pattern.md).

---

# Part 1 — Decode the Ignition 8.3 file structure

## Tour: the `data/` directory (guided, ~20 min)

Walk the gateway's `data/` directory live, both from the inside (via `docker exec`) and from the outside (the host bind mounts).

```bash
docker exec -it lab04-ignition-local bash -lc "ls -la /usr/local/bin/ignition/data"
```

In order:

1. **`projects/<name>/`** — project-level state. One directory per project. Inside: `project.json` + module-namespaced resource folders, e.g. `com.inductiveautomation.perspective/views/pages/<Page>/{view.json, resource.json}` and `ignition/`. *This is the thing you'll deploy via file-based CI/CD.*
2. **`config/resources/<scope>/`** — gateway-level config, organized scope-first (`core`, `loc`/`dev`/`prd`, `local`) then by module: `core/ignition/database-connection/<name>/`, `identity-provider/<name>/`, `tag-provider/<name>/`. Shared across all projects.
3. **`config/`** root — gateway-level non-resource config (small).
4. **`modules.json`** — which modules the gateway has enabled. Gateway-level. (Repo source: `services/modules.json`.)
5. **`modules/`** — the actual installed module binaries (`.modl` files). Almost never committed to git; usually managed separately.
6. **`db/`** — the internal SQLite DB (`config.idb`), which includes the internal user store (password hashes, lockout state). **Operational state.** Never commit.
7. **`jar-cache/`, `metricsdb/`, `var/`, `.resources/`** — runtime / generated stuff (the last is Ignition's content-addressed blob store). Never commit. (Gateway logs live outside `data/`, at the install root.)

The three-bucket model:

```
PROJECT-LEVEL     GATEWAY-LEVEL              OPERATIONAL
projects/<x>/     config/resources/          db/, jar-cache/,
                  modules.json               metricsdb/, var/
                  modules/                   (anything that changes at runtime
                                              without you touching the gateway)
```

The deploy story is different for each bucket:

- **Project-level:** copy → trigger project scan. No restart needed.
- **Gateway-level:** copy → trigger config scan. *Sometimes* a restart is needed (depends on what changed).
- **Operational:** never deployed. Gateway owns this state; backups are the recovery mechanism.

## Find the file (guided, ~20 min)

The marker trick: set a timestamp marker, make the change in the UI, then ask `find` what's newer.

1. `docker exec -it lab04-ignition-local bash -lc "ls -la /usr/local/bin/ignition/data"` — list every top-level entry. Note what each is. (Operational paths like `db/`, `jar-cache/`, `metricsdb/` live in the container's named volume, so you'll only see them via `docker exec`, not on the host bind mount.)
2. **Set a marker** so you can spot which files a UI change touches:
   ```bash
   docker exec lab04-ignition-local touch /tmp/marker
   ```
3. In the gateway UI, go to **Config → Networking → Web Server**. Change the *Idle Timeout* to something different (default is 300). Save.
4. Find the file that changed on disk:
   ```bash
   docker exec lab04-ignition-local find /usr/local/bin/ignition/data/config -newer /tmp/marker -type f 2>/dev/null
   ```
5. Open that file with `docker exec lab04-ignition-local cat <path>`. Notice what's in there — it'll be a `config.json` (plus the gateway rewriting a sibling `resource.json`).
6. In the gateway UI, **Config → Databases → Connections → New**. Add a Postgres datasource. In 8.3.6 the create form takes a single **Connect URL**: `jdbc:postgresql://timescaledb:5432/ignition_loc`, user/password from your `.env` (`POSTGRES_USER` / `POSTGRES_PASSWORD`, default `ignition` / `ignition`). Save. The hostname `timescaledb` is the compose service name — the local gateway resolves it on the lab's docker network.
7. Repeat step 4 (re-touch the marker first) — find the new files. The connection lands at `config/resources/<scope>/ignition/database-connection/<name>/config.json`. Gateway-level or project-level? Because `local` bind-mounts `./services/config/`, it also just appeared **in your repo on the host** — run `git status`.

## "Everything is a file in git" (guided)

Prove that the things people assume live "inside Ignition somewhere" are all plain files you can read, diff, and commit. Do these from the repo root on your host (no gateway needed — they're already on disk under `services/` and `projects/`).

1. **Every database connection is a file.** Open `services/config/resources/core/ignition/database-connection/TimescaleDB/config.json`. This is the whole connection: JDBC URL, pool sizes, the (encrypted) password. Nothing hidden in a gateway database.

2. **Every PLC / device connection is a file.** Open `services/config/resources/core/com.inductiveautomation.opcua/device/Simulator/config.json` and `.../ignition/opc-connection/Ignition OPC UA Server/config.json`. The lab ships a **simulator** device on disk; in a real plant this same file would describe your Modbus / OPC-UA PLC. Your PLC wiring is version-controlled, reviewable config, not clicks in a UI.

3. **Tags are files too.** Open `services/config/resources/core/ignition/tag-definition/example-tags/tags.json` (and the UDT definitions under `ignition/tag-type-definition/example-tags/udts.json`). Tag providers, tags, and UDTs all serialize to JSON on disk. (The runtime *values* live in `services/config/ignition/tags/valueStore.idb`, which is operational and never committed — the definitions are, the live values are not.)

4. **Deployment modes: one config set, many environments.** This is an Ignition 8.3 platform feature, not a lab trick. The scopes you saw (`core`, `loc`, `dev`, `prd`) are **deployment modes**: the same resource name resolves to different settings per mode, and the gateway picks the mode at boot with `-Dignition.config.mode=<scope>`. See it directly:
   ```bash
   diff services/config/resources/loc/ignition/database-connection/TimescaleDB/config.json \
        services/config/resources/prd/ignition/database-connection/TimescaleDB/config.json
   ```
   Exactly one line differs: the `connectURL` points at `ignition_loc` vs `ignition_prd`. Same connection *name*, same everything else (that falls through to `core`), one per-mode override. The real-world version: a device named `PLC-01` is a **simulator in dev** and the **real device in prod**, under one name, so your project code never changes.

5. **Where is the CSS "hidden"?** In Perspective, styling lives in a few honest places, all of them files:
   - **Inline component styles** live right in the view: open `projects/example-project/com.inductiveautomation.perspective/views/pages/refrigeration/view.json` and find the `style` props on components.
   - **Style classes** (reusable named styles) are a *project resource* under `com.inductiveautomation.perspective/style-classes/<name>/` when a project defines them. This repo styles inline, so it has none, but that is where they land.
   - **Themes** (the gateway-wide look) are gateway-level theme CSS the gateway generates under `data/`.

   The takeaway: there is no secret CSS store. It is inline in views, or a style-class resource, or a gateway theme file — all readable, all diffable.

## Solo: make three changes, classify every one (~30 min)

Make a series of changes in the gateway UI and answer: **which bucket is each in, and where does it live on disk?**

Pick three changes from this list (or invent your own). For each note:

- **What you changed** (one sentence)
- **Where it lives on disk** (path relative to `data/`)
- **Bucket**: project-level / gateway-level / operational
- **One sentence: would you commit this to git?**

> This repo ships **two** projects under `projects/`: `example-project` and `packaging-site`. Each project is a self-contained directory; the gateway config (connections, tags, deployment modes) is **shared** across both. That split — per-project resources vs one shared gateway config — is the whole point of the project-level vs gateway-level buckets.

Suggested changes:

1. Add a **Perspective view** to one of the two projects. No Designer? Simulate on disk: create `projects/packaging-site/com.inductiveautomation.perspective/views/pages/<Name>/{view.json, resource.json}` with the minimal 8.3 content from [`docs/ignition-file-structure.md`](../docs/ignition-file-structure.md). Note the `resource.json` manifest is **required** in 8.3, and that this lands under *one* project only, unlike a gateway resource.
2. Change the **gateway timezone** (Config → System → Time)
3. Add a **new user** to the gateway (Config → Security → Users)
4. Add a **new tag provider** (Config → Tags → Realtime Tag Providers)
5. Enable a **new module** (toggle a module in Config → Modules)

Use the marker trick every time: re-touch before each change, `find -newer` after. One of the five lands somewhere that must **never** go in git. Which?

## Definition of done (part 1)

You're finished with part 1 when you can, without peeking:

- [ ] List the top-level `data/` entries and say which **bucket** each is (project / gateway / operational).
- [ ] Make a UI change and **find the file it wrote** on disk with the `/tmp/marker` + `find -newer` trick.
- [ ] State the real 8.3 path shape for a view (`projects/<x>/com.inductiveautomation.perspective/views/...` + `resource.json`) and a config resource (`config/resources/<scope>/<module>/<type>/<name>/config.json`).
- [ ] Point at the on-disk file for a database connection, a PLC/device connection, and a tag definition, and explain why "it's all in git" follows.
- [ ] Explain **deployment modes** in one sentence (one config set, per-mode overrides selected at boot) and name what differs between the `loc` and `prd` `TimescaleDB` connection.
- [ ] Explain why `db/` and `.resources/` must **not** be committed.

## Stretch `[OPTIONAL]` — draft the `.gitignore`

You now know the operational bucket. Turn that knowledge into ignore patterns — the precursor to `.deployignore`, which the deploy part puts to work.

Draft a starter `.gitignore` for an Ignition project repo. Cover the **operational bucket**: the internal DB, tag value stores, caches, blob stores. Then compare with the shipped [`.gitignore`](../.gitignore). What did you miss? What did the shipped one miss?

Commonly forgotten: `config/resources/local/` (instance identity), `*.gwbk` (backups), `*.modl` (module binaries), `config/ignition/tags/*.idb` (tag value stores inside the versioned config tree).

---

# Part 2 — Build the file-based deploy

The file-based pattern, end-to-end across the three lab gateways.

The five steps:

1. **Developer commits** to `projects/<name>/` on a `feature/*` branch off `develop`, then opens a PR into `develop`.
2. **Runner checks out** the merged commit (after the PR merges into `develop`). The bundled `github-runner` container handles this.
3. **Runner prunes** the working tree per `.deployignore` so lab-only files (READMEs, docs, scripts) don't pollute the gateway.
4. **Runner ships** the files into the target gateway container via `docker cp` (dev and prod use named volumes — no shared filesystem with the runner).
5. **Runner calls** `POST /data/api/v1/scan/{projects,config}` to make the gateway notice the change without a restart.

## The deploy, by hand, once (guided, ~20 min)

```bash
# Add a tiny project on disk (simulating what a developer commit would produce).
# Because `local` bind-mounts ./projects/, these files are already on the local
# gateway's disk before we do anything else. Note the 8.3 module-namespaced path
# and the required resource.json manifest.
VIEW="projects/sample/com.inductiveautomation.perspective/views/Hello"
mkdir -p "$VIEW"
cat > projects/sample/project.json <<'EOF'
{"title":"Sample","description":"Demo project","enabled":true,"inheritable":false,"parent":""}
EOF
cat > "$VIEW/view.json" <<'EOF'
{"custom":{},"params":{},"props":{"defaultSize":{"height":600,"width":800}},
 "root":{"type":"ia.container.coord","version":0}}
EOF
cat > "$VIEW/resource.json" <<'EOF'
{"scope":"G","version":1,"restricted":false,"overridable":true,"files":["view.json"],"attributes":{}}
EOF

# Trigger a project scan on the local gateway:
scripts/scan.sh projects --gateway local
```

In the local gateway UI (http://localhost:8088), the `sample` project should now appear (Config → Projects, or the Perspective project launcher).

Now edit a view and ship it to dev by hand — this is exactly what `deploy.yml` automates:

1. Change `projects/sample/com.inductiveautomation.perspective/views/Hello/view.json` (e.g., `width: 800` → `width: 1200`).
2. Scan the **local** gateway — local sees the change via bind mount immediately; the scan tells it to notice:
   ```bash
   scripts/scan.sh both --gateway local
   ```
   Verify in http://localhost:8088 — the view's width should match.
3. Copy the same change to **dev** manually:
   ```bash
   # Wipe only projects/ (so a deleted-in-repo view disappears). Do NOT wipe
   # config/: the gateway owns state there (its scan API token, its per-instance
   # identity under resources/local/). docker cp merges config/ on top.
   docker exec lab04-ignition-dev sh -c \
     "rm -rf /usr/local/bin/ignition/data/projects/*"
   docker cp ./projects/.        lab04-ignition-dev:/usr/local/bin/ignition/data/projects/
   docker cp ./services/config/. lab04-ignition-dev:/usr/local/bin/ignition/data/config/
   scripts/scan.sh both --gateway dev
   ```
   Verify in http://localhost:8089 — the same view should appear, the same width.
4. Inspect `.deployignore`. Notice it excludes `README.md`, `LICENSE`, the `.github/` directory, `docs/`, `scripts/`, and the per-instance `services/config/resources/local/`. For each pattern, say **why the gateway shouldn't have that file**.

> **No sample project?** Use any view under the shipped `projects/example-project/` instead — the flow is identical.

The runner topology:

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

The runner doesn't share a bind-mounted filesystem with dev/prod — they each have a named volume. The runner reaches *inside* the container with `docker cp` instead. (Local is different: it bind-mounts `./projects/` and `./services/config/`, so changes show up without any copy step.)

## Solo: wire the flow into GitHub Actions (~40 min)

### Part 2.1 — Verify the runner is up (5 min)

The runner is already running as part of the compose stack. Confirm it:

```bash
docker compose ps github-runner
docker compose logs --tail 50 github-runner   # look for "Listening for Jobs"
```

In your fork on GitHub, *Settings → Actions → Runners* should show the runner online with the `self-hosted, lab04` labels. If it's not there:

- `RUNNER_REPO_URL` in `.env` must point at your fork (not the upstream).
- `gh` must be installed and authenticated (`gh auth status`) so `setup.sh` could mint the registration token — re-run `scripts/setup.sh` after fixing it.
- Restart it: `docker compose restart github-runner`.

### Part 2.2 — GitHub environments + secrets (10 min)

In your fork:

1. *Settings → Environments → New environment*: `lab-gateway-dev`.
2. Under that environment, *Add secret*: `IGNITION_API_KEY` = the API key you generated **on the dev gateway** (its UI is at http://localhost:8089).
3. Repeat for `lab-gateway-prod` with the API key generated **on the prod gateway** (http://localhost:8090).

> **API keys are per-gateway, not per-URL.** You generate each key in *that gateway's* UI; the dev key won't authenticate against prod. The host ports (8089/8090) are just how *you* reach the UIs — the **runner** reaches the same gateways by their compose service names (`http://ignition-dev:8088`, `http://ignition-prod:8088`), which is why `IGNITION_URL`'s default differs from the host port.

You **don't** need to set `IGNITION_URL` or `IGNITION_CONTAINER` variables unless your runner topology differs from the lab's — the workflow defaults match the bundled runner.

### Part 2.3 — Ship to dev via `develop` (15 min)

> **Prerequisite:** the change below needs the `sample` project to be *committed* (the guided steps left it untracked). Commit it to `develop` first:
> ```bash
> git add projects/sample && git commit -m "Add sample project"
> git push origin develop
> ```
> No `sample` project? Use any view under `projects/example-project/` instead.

1. Branch a feature off `develop` and change a view:
   ```bash
   git checkout develop && git checkout -b feature/tweak-view
   # edit projects/sample/com.inductiveautomation.perspective/views/Hello/view.json — change the height value
   git commit -am "Tweak Hello view height"
   git push -u origin feature/tweak-view
   ```
2. Open a PR **into `develop`**. Watch [`ci.yml`](../.github/workflows/ci.yml) run on `ubuntu-latest` (free): it validates JSON, `.deployignore`, and the workflow files themselves.
3. Merge the PR into `develop`. [`deploy.yml`](../.github/workflows/deploy.yml) fires because of the `paths:` filter (and only on `develop`).
4. Watch the workflow run. The interesting steps are **Ship projects and config into gateway container** (the `docker cp` half) and **Trigger gateway scan** (`POST /data/api/v1/scan/{projects,config}`).
5. Verify in http://localhost:8089 — the view's height should match what you pushed.
6. **Multi-project check.** The deploy step copies `./projects/.` (the whole directory), so a single merge deploys **both** `example-project` and `packaging-site` at once. Confirm the dev gateway (Config → Projects) lists **both**, even though your PR only touched a view in one. The unit of deploy is the `projects/` tree, not a single project.

### Part 2.4 — Release to prod via `main` + tag (10 min)

Cut a release the Git Flow way: bring `develop` to `main` (here, a simple merge stands in for a `release/*` branch), then tag. The **tag** — not the merge — is what ships to prod.

```bash
git checkout main && git pull
git merge --no-ff develop -m "Release v0.1.0"
git push origin main          # ← nothing happens
git tag v0.1.0
git push origin v0.1.0        # ← release.yml fires
```

[`release.yml`](../.github/workflows/release.yml) fires on the tag. Watch it run, then check http://localhost:8090 — the change you merged through `develop` and just released should be visible on prod. The merge into `main` did nothing on its own; the **tag** is the trigger, so prod always runs a named, re-deployable version. That's also your rollback button: `release.yml`'s `workflow_dispatch` takes a tag input.

### Part 2.5 — Break a deploy on purpose (optional, ~5 min)

Cause one of these and read the workflow output:

- **Wrong API key.** Set garbage in `lab-gateway-dev`'s secret, re-run the deploy. The **Ship step succeeds** (`docker cp` doesn't care about keys) but the **scan 403s**. Files are in the container; the gateway never reloaded. *What's your recovery story?*
- **Stopped container.** `docker compose stop ignition-dev`, then trigger a deploy. The **verify step fails fast** ("container is in state 'exited', expected 'running'") before any file moved — much better than failing halfway.

Then fix it and re-run (manual `workflow_dispatch` works too). The steps are idempotent, so the deploy converges.

For your chosen failure, write down: **symptom → state of the gateway → recovery → which workflow step should have caught it earlier?**

## Definition of done (part 2)

- [ ] The bundled runner shows **online** in your fork (`self-hosted, lab04`).
- [ ] Both GitHub environments (`lab-gateway-dev`, `lab-gateway-prod`) exist, each with an `IGNITION_API_KEY` secret.
- [ ] A PR merged **into `develop`** triggered `deploy.yml` and the change is visible on the **dev** gateway (:8089).
- [ ] A `v*` tag on `main` triggered `release.yml` and the change is visible on the **prod** gateway (:8090).
- [ ] You broke **one** deploy on purpose and can describe the failure mode and recovery.
- [ ] You can name the Git Flow branch → gateway mapping (`develop` → dev, tag on `main` → prod) and explain, in five steps, what the runner does between "merge" and "gateway reloaded."

## Stretch `[OPTIONAL]` — the `modules.json` puzzle

Gateway-level config (the contents of `services/config/`) ships the same way `projects/` does — both workflows `docker cp ./services/config/.`. But not every gateway change rides that path, and not every change a scan can apply:

- **Module enablement** lives in `services/modules.json` — a *sibling* of `services/config/`, **not under it**. The deploy workflows copy `./services/config/.`, so `modules.json` is **not shipped** by them; in this lab it's bind-mounted into all three gateways. Open `deploy.yml` and confirm the `docker cp` targets.
- Even with a new `modules.json` on the gateway, **a scan won't apply it** — module enable/disable needs a gateway **restart** (`docker compose restart ignition-dev`), unlike views/config which hot-reload on scan.

So the question to chew on: why does copy + scan work beautifully for views and database connections, but not for modules? List everything else a scan could never apply (memory, Java args, module binaries…). What does that tell you about where the image-based deploy (Lab 05) earns its keep?

---

## Debrief

- What surprised you about the on-disk layout? Which bucket has the trickiest deploy story? (Hint: the one that *sometimes* needs a restart.)
- For your current customer's CI/CD: where does each bucket live, and which are versioned?
- What happens if the runner crashes mid-deploy? The `docker cp` is *not* atomic — what does the gateway do with a partially-copied project?
- What's the rollback story? Git Flow gives you two levers: revert a bad merge on `develop` (re-deploys **dev**), or re-deploy a known-good tag to **prod** via `release.yml`'s `workflow_dispatch`. Which applies to which gateway, and why?
- Where would the self-hosted runner sit on your customer's network? What does it need access to that GitHub-hosted runners don't have?

> **Next:** baking this into images is Lab 05. Bring your `modules.json` stretch answer.
