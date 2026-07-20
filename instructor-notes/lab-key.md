# Lab 04 — instructor answer key

> **Do not read this before you've attempted the solo work.** For part 1, the classification skill *is* the lesson — if you peek you'll memorize answers instead of building the mental model. For part 2, the interesting content is in the failure-case discussion.

---

# Part 1 — Ignition file structure

## Goal recap

By the end of part 1, participants can answer *"Which bucket, and where on disk?"* for any change they make in the gateway UI. The three-bucket model (project-level / gateway-level / operational) is the central artifact.

## Classification reference

All paths are the real 8.3 layout: project resources are namespaced by owning module, and config resources are `config/resources/<scope>/<module-id>/<resource-type>/<name>/{config.json, resource.json}` (scope is usually `core` for portable config). Expect a longer `find` result than an 8.1-style flat path.

| Change | Bucket | On-disk path | In git? |
|---|---|---|---|
| Create a new Perspective view in project X | Project-level | `data/projects/X/com.inductiveautomation.perspective/views/<group>/<Name>/{view.json, resource.json}` | Yes |
| Add or modify a script library in project X | Project-level | `data/projects/X/ignition/script-python/<library>/` | Yes |
| Add a UDT / tag definition | Gateway-level | tag config under `config/resources/core/ignition/tag-definition/` and `.../tag-type-definition/` | Yes |
| Change a project's title/description | Project-level | `data/projects/X/project.json` | Yes |
| Change gateway timezone (Config → System → Time) | Gateway-level | under `config/resources/core/ignition/system-properties/config.json` (path may shift between 8.3 minor versions) | Yes — but often gitignored and set via env |
| Add a database connection | Gateway-level | `data/config/resources/core/ignition/database-connection/<name>/config.json` | Yes |
| Add a historian connection | Gateway-level | `data/config/resources/core/com.inductiveautomation.historian/historian-provider/<name>/config.json` | Yes |
| Add a new identity provider (OIDC/SAML) | Gateway-level | `data/config/resources/core/ignition/identity-provider/<name>/config.json` | **Yes** — an external IdP holds no password data (users live in the IdP), so it's tracked config that deploys normally. Only the gateway-owned **internal** `identity-provider/default/` (and `user-source/default/` + `user-source/opcua-module/`) is per-gateway: untracked, `.deployignore`d, spared by the deploy wipe |
| Enable / disable a module | Gateway-level | `data/modules.json` (repo: `services/modules.json`) | Yes |
| Install a new module (.modl) | Gateway-level binary | `data/modules/<module>.modl` | Yes / No |
| Add a new gateway user (UI-managed) | Operational | `data/config/resources/core/ignition/user-source/default/users.json` (the internal default user source — untracked; runtime auth state like lockouts rides in `data/db/config.idb`) | **No** |
| Change the gateway admin password | Operational | `data/config/resources/core/ignition/user-source/default/users.json` (password hashes) | **No** |
| Tag values changing at runtime | Operational | `data/config/ignition/tags/valueStore.idb` (masked by `.gitignore`) | **No** |
| Wrapper logs filling up | Operational | `logs/` at the install root (outside `data/`) | **No** |

If a participant classifies something incorrectly, walk them through the two questions:

1. *Would this file be different on a teammate's identical clone?* If yes → operational.
2. *Would I want this in git history?* If yes → versioned.

These handle ~99% of cases.

## Common stumbles

- **"I added a user in the UI — where did it land, should I commit it?"** It landed in `users.json` inside the **default (internal) user source** — `config/resources/core/ignition/user-source/default/users.json` — which carries password hashes and is deliberately untracked (gitignored, `.deployignore`d, spared by the deploy wipe), like the rest of the internal identity (`user-source/opcua-module/`, `identity-provider/default/`). Never commit `db/` either: the internal SQLite DB (`data/db/config.idb`) holds runtime auth state (last-login timestamps, lockout state), and a `gwbk` backup carries the same data. The source-controlled pattern for real user management is a database/AD user source or an external identity provider (OIDC/SAML) — those hold no password data, so they're tracked config that deploys normally.
- **"Why isn't `modules/` in git?"** `.modl` files are 5-100 MB binary blobs keyed by license/vendor. Pin versions in a manifest; install separately. (Lab-05 revisits this with derived Docker images.)
- **"I changed the timezone but can't find the file."** The path is sometimes config-mode dependent, and 8.3 has shifted some config from XML to JSON across minor releases. The `find ... -newer /tmp/marker -type f` trick handles this: the file *will* be newer than the marker. **Prerequisite:** the marker only works if they ran `docker exec lab04-ignition-local touch /tmp/marker` *before* the UI change. If they forgot, re-touch and redo. Expect a sibling `resource.json` to also be rewritten — that's the gateway's manifest.
- **"I made a Perspective change in the Designer but nothing's on disk."** Did they *save* in the Designer? Unsaved changes live only in Designer memory.

## Notes on the lab gateways

The `local` gateway is the only one that uses **host bind mounts** for `projects/` and `services/config/`:

- Any file you put in `<repo>/projects/sample/` is *immediately* at `<gateway>/data/projects/sample/` — no `docker cp`.
- Anything the local gateway writes to those paths shows up *on your host*. Demonstrate live: make a UI change, then `ls projects/` on the host.

`data/db/`, `data/jar-cache/`, `data/metricsdb/`, `data/var/` stay inside the named volume — students don't see them by default. `docker exec lab04-ignition-local ls /usr/local/bin/ignition/data/` shows the full tree.

The `dev` and `prod` gateways bind-mount **only** their `projects/` and `config/` to `./gateways/dev/` and `./gateways/prod/` (gitignored, created by `setup.sh`); the rest of their `data/` stays in named volumes. That's deliberate: deploys become **observable from the host** (`ls gateways/dev/projects` shows exactly what CI shipped), which named volumes made painful. The teaching point stays the same — you ship files via CI, you don't hand-edit dev/prod state on the host; the bind mounts are a window, not an editing surface. Part 2 is where students touch those.

## Solo grading

Strong solo notes have: a real change made in the UI (not just classified hypothetically); the actual on-disk path (not "somewhere in `config/`"); an explicit bucket; and a clear in-git decision with reasoning. A solo that just lists three predefined answers from this key doesn't earn it — push them to make at least one change of *their own* choosing.

## Stretch — `.gitignore` for a real Ignition repo

```gitignore
# Operational state — never commit
data/db/
data/jar-cache/
data/metricsdb/
data/var/
data/config/resources/.resources/
data/config/ignition/tags/*.idb
data/config/local/
data/config/resources/local/

# The gateway-owned INTERNAL identity — users.json holds admin password hashes.
# Only these named dirs: identity resources you add (DB/AD user sources,
# SAML/OIDC providers) and security-properties are tracked, deployable config.
data/config/resources/core/ignition/user-source/default/
data/config/resources/core/ignition/user-source/opcua-module/
data/config/resources/core/ignition/identity-provider/default/

# Module binaries — manage separately
data/modules/*.modl

# Gateway backup files
*.gwbk

# Compose local-only files
.env
```

Commonly missed: `data/config/local/` and `data/config/resources/local/` (per-instance identity: keystores, UUID); the internal identity by name — `user-source/default/`, `user-source/opcua-module/`, `identity-provider/default/` (admin password hashes) — while noting that other user sources/IdPs and `security-properties` are tracked config; `data/config/ignition/tags/*.idb` (tag value stores inside the versioned config tree); backup files (`*.gwbk`); module binaries (`*.modl`).

## Debrief crib

- **"What surprised you?"** Common answer: how much is *operational*, not config — and that the user store (password hashes included) rides inside `db/config.idb` and every `gwbk`, which regularly end up in git without anyone realising.
- **"Which bucket has the trickiest deploy?"** Gateway-level. Some changes hot-reload via scan; others need restart.
- **"Smallest atomic change?"** A single view's JSON file, ~1 KB. Part 2 deploys exactly this kind of change end-to-end.

Before students move to part 2:

- Remind them part 2 uses the bundled `github-runner` container — needs `RUNNER_REPO_URL` in `.env` pointed at their fork and a `repo`-scope PAT in `RUNNER_GITHUB_PAT`. This is the lab where they create that PAT; Labs 05 and 06 reuse it. A placeholder PAT shows up as a 401 restart-loop in `docker compose logs github-runner`.
- API keys need no gateway-UI work: `setup.sh` already generated a unique key per gateway into `.env` (`IGNITION_API_KEY_LOCAL/_DEV/_PROD`) and installed the hash-only token resources. Have them copy the `_DEV` / `_PROD` values into environment-scoped secrets on the `lab-gateway-dev` / `lab-gateway-prod` GitHub environments. Teaching point: nothing key-related is in git — earlier course iterations committed the token, i.e. shipped a working credential in every fork.
- Confirm Actions is enabled on their fork — the #1 "nothing deployed" stumble (forks ship with workflows disabled; a docs-only push also won't trip the `paths:` filter).

---

# Part 2 — File-based deploy

## What success looks like

By the end of part 2, the participant has:

1. The bundled `github-runner` online — visible in their fork as `self-hosted, lab04`.
2. Two GitHub environments (`lab-gateway-dev`, `lab-gateway-prod`), each with `IGNITION_API_KEY` as an environment-scoped secret.
3. Edited a view on a `feature/*` branch, opened a PR **into `main`**, watched CI pass, merged. (The sample project must be committed to `main` first.)
4. Watched `deploy.yml` run end-to-end: checkout → verify prereqs → prune → ship (docker cp) → scan → smoke-check.
5. Verified the change on the **dev** gateway (http://localhost:8089).
6. Tagged a commit on `main` with `v*`, watched `release.yml` promote the same change to **prod** (http://localhost:8090).
7. Deliberately broken at least one deploy and read the failure mode.

If any is missing — especially #6 — push them to complete. The failure cases are half the lesson.

## The five-step pattern

1. **Commit:** developer edits a view on a `feature/*` branch, opens a PR **into `main`**. PR merges into `main`.
2. **Checkout:** the bundled runner picks up the push to `main`, checks out the merged commit.
3. **Prune:** the runner reads `.deployignore` and removes those files from the working tree before they can ship.
4. **Ship:** `docker exec` wipes the target's `projects/` and `config/` dirs — preserving the five gateway-owned entries `.deployignore` protects (`config/local/`, `config/resources/local/`, and the internal identity by name: `config/resources/core/ignition/user-source/default/`, `user-source/opcua-module/`, `identity-provider/default/`) — then `docker cp` writes the working tree into the gateway's container.
5. **Scan:** an inline `POST /data/api/v1/scan/{projects,config}` against the gateway. Gateway re-reads disk.

## The shipped `deploy.yml`, annotated

```yaml
on:
  push:
    branches: [main]                # GitHub Flow: deploy on pushes to the single long-lived branch
    paths:                          # skip workflow on docs-only changes
      - "projects/**"
      - "services/config/**"
      - ".deployignore"
      - "scripts/scan.sh"
      - "scripts/lib.sh"
      - ".github/workflows/deploy.yml"
  workflow_dispatch:                # let humans trigger manually for testing

permissions:
  contents: read                    # least privilege

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
      - name: Verify deploy prerequisites          # fail fast — docker, API key, container running
      - name: Prune working tree per .deployignore  # in-checkout rm -rf for matched paths/names
      - name: Ship projects and config into gateway container
        run: |
          # Wipe-then-copy: projects/ AND config/, so a deleted-in-repo resource
          # disappears from the gateway too. Preserve the entries .deployignore
          # prunes (and thus never copies back): config/local/ and
          # config/resources/local/ (UUID, OPC-UA keystores, machine-local props)
          # plus the gateway-owned INTERNAL identity by name —
          # user-source/{default,opcua-module}/ and identity-provider/default/
          # (users.json holds THIS gateway's admin hash), and api-token/ (the
          # scan key setup.sh generated — not in git, so wiping it would revoke
          # the key this very scan uses). Everything else under config/ is
          # repo-owned and wiped + copied fresh, incl. security-properties
          # (permission policy) and any identity resources you added yourself
          # (DB/AD user sources, SAML/OIDC providers — no password data).
          docker exec "$IGNITION_CONTAINER" sh -c "
            set -eu
            rm -rf '$GATEWAY_DATA_PATH/projects/'*
            find '$GATEWAY_DATA_PATH/config' -mindepth 1 -maxdepth 1 \
              ! -name local ! -name resources -exec rm -rf {} +
            if [ -d '$GATEWAY_DATA_PATH/config/resources' ]; then
              find '$GATEWAY_DATA_PATH/config/resources' -mindepth 1 -maxdepth 1 \
                ! -name local ! -name core -exec rm -rf {} +
            fi
            if [ -d '$GATEWAY_DATA_PATH/config/resources/core' ]; then
              find '$GATEWAY_DATA_PATH/config/resources/core' -mindepth 1 -maxdepth 1 \
                ! -name ignition -exec rm -rf {} +
            fi
            if [ -d '$GATEWAY_DATA_PATH/config/resources/core/ignition' ]; then
              find '$GATEWAY_DATA_PATH/config/resources/core/ignition' -mindepth 1 -maxdepth 1 \
                ! -name user-source ! -name identity-provider -exec rm -rf {} +
            fi
            if [ -d '$GATEWAY_DATA_PATH/config/resources/core/ignition/user-source' ]; then
              find '$GATEWAY_DATA_PATH/config/resources/core/ignition/user-source' -mindepth 1 -maxdepth 1 \
                ! -name default ! -name opcua-module -exec rm -rf {} +
            fi
            if [ -d '$GATEWAY_DATA_PATH/config/resources/core/ignition/identity-provider' ]; then
              find '$GATEWAY_DATA_PATH/config/resources/core/ignition/identity-provider' -mindepth 1 -maxdepth 1 \
                ! -name default -exec rm -rf {} +
            fi
          "
          docker cp ./projects/.        "$IGNITION_CONTAINER:$GATEWAY_DATA_PATH/projects/"
          docker cp ./services/config/. "$IGNITION_CONTAINER:$GATEWAY_DATA_PATH/config/"
      - name: Trigger gateway scan
        run: |
          # Inline curl, NOT scripts/scan.sh: the prune step removed
          # scripts/ (it is in .deployignore), so the script is not on disk here.
          for what in projects config; do
            curl -sS -X POST -H "X-Ignition-API-Token: $IGNITION_API_KEY" \
              "$IGNITION_URL/data/api/v1/scan/$what"  # check for HTTP 2xx
          done
          # Self-heal (abridged — see the real file): on HTTP 401 (token never
          # loaded) or 403 (commissioning reset the permissions), restart the
          # gateway once — Ship already put the token + security-properties on
          # its disk, loaded at boot — wait for RUNNING, retry the scans.
          # First deploy to a fresh gateway heals itself; later deploys scan hot.
      - name: Smoke-check gateway health            # poll /StatusPing for 20s
```

Highlights for the grade:

- **Least-privilege permissions.** `contents: read` is enough.
- **`branches: [main]`.** Only pushes to main deploy to dev. Prod is reached by tagging (`release.yml`). Most common point of confusion.
- **`paths:` filter.** Docs-only changes don't retrigger the deploy.
- **`concurrency` block.** `cancel-in-progress: false` queues a new run rather than cancelling an in-flight one — cancellation mid-`docker cp` would leave a partial state.
- **Wipe `config/`, but spare what `.deployignore` prunes.** The wipe deletes everything under `projects/` and `config/` *except* the six entries `.deployignore` protects: `config/local/` and `config/resources/local/` (UUID, OPC-UA keystores, machine-local props), plus the gateway-owned **internal** identity by name — `config/resources/core/ignition/user-source/default/`, `user-source/opcua-module/`, and `identity-provider/default/`. Note the last three are name-scoped *inside* `user-source/` and `identity-provider/`: other user sources and identity providers in those dirs (database/AD, SAML/OIDC — no password data) are repo-owned and get wiped and redeployed like anything else, as does `security-properties` (permission policy, committed with `systemAuthProfile=default`, which every gateway has). The spared entries are pruned from the working tree, so a blanket `rm -rf config/*` would delete them with nothing to copy back — stripping the gateway's identity, and in the user-source case deleting `users.json` out from under the *running* gateway, breaking logins instantly. War story worth telling: an earlier course run committed the local gateway's user source, so the first prod deploy overwrote prod's admin user with local's hash — everyone locked out, volumes wiped to recover. The scan API token at `config/resources/core/ignition/api-token/` is the fourth name-scoped spare: it is **generated per clone** by `setup.sh` (never committed — a committed token is a working credential in every fork), so the wipe must leave it in place or the deploy would revoke the very key it scans with. The rule: **wipe = repo-owned; preserve = whatever `.deployignore` prunes.**
- **Inline scan, not the script.** The prune step deletes `scripts/` (it's in `.deployignore` and nothing ships it), so the scan must not depend on `scripts/scan.sh`. `scan.sh` stays for manual/local use.
- **`environment:` scoping.** Secrets scoped to `lab-gateway-dev`. A repo-level `IGNITION_API_KEY` won't be picked up — deliberate. Environments give per-target secrets and deploy history for free.
- **Verify + smoke-check.** Cheap; catch missing key / stopped container before any file moves, and a broken gateway after.

`release.yml` is structurally the same — different trigger (`tags: ['v*']`), environment (`lab-gateway-prod`), default URL (`ignition-prod`).

## Common stumbles

- **"I merged my PR but nothing deployed."** (a) The change didn't touch a deploy path, so the `paths:` filter skipped `deploy.yml` (docs-only, README, etc.); (b) Actions isn't enabled on their fork (forks ship with workflows disabled). Fix: touch a path under the filter, and enable Actions in the fork's *Actions* tab.
- **"I pushed to `main` and expected prod to update."** Merging into `main` deploys to **dev** only — prod is reached by **tagging**. By design: prod always runs a named version.
- **"My runner isn't picking up jobs."** Container running (`docker compose ps github-runner`), `RUNNER_REPO_URL` points at the **fork**, and `RUNNER_GITHUB_PAT` is a real `repo`-scope PAT (a bad one is a 401 in `docker compose logs github-runner`). Fix and `docker compose up -d --force-recreate github-runner`.
- **"The deploy ran but my change isn't visible."** Did `Ship` succeed (docker cp output)? Did the scan return HTTP 200? Are they looking at **dev** (8089) or **local** (8088)?
- **"The scan step 403'd (or 401'd)."** 403 = the API key's role lacks Project/Config Scan **or** the gateway's Read/Write permissions (Config → Security → General Settings) don't admit the token's security level (`Authenticated`). 401 = the token isn't recognized. In **CI this is now self-healing**: the scan step catches a 401 (fresh gateway never loaded the token) or 403 (commissioning reset the permissions in security-properties), restarts the gateway once — Ship already copied the token and security-properties onto its disk, and the gateway loads them at boot — waits for RUNNING, and retries. So the *first* deploy to an unprepared gateway (even one started with plain `docker compose up`) goes green on its own; later deploys scan hot. Where students still hit this is **manual scans** (`scripts/scan.sh`) before any deploy has run: `setup.sh` handles that by generating each gateway's key into `.env` (`scripts/generate-api-keys.sh`) and writing the hash-only token into `services/config` (local) and `gateways/{dev,prod}/config` *before* first boot, and self-heals: if a probe still 401s, it re-seeds the token and restarts that gateway, then falls through to the 403 permission repair (`fix-gateway-api-perms.sh`). Fix for manual scans: re-run `scripts/setup.sh`. Note the token is **not** in git (deliberately — no credentials in commits) and the deploy wipe **spares** `api-token/` on the gateway, so the key survives every deploy and restart; because the hash is derived from the key, `.env` is the single source of truth and a wiped config tree is re-derived by re-running `setup.sh`. A token hand-made in the gateway UI works too, as long as the matching key goes into `.env`/the GitHub secret — the wipe spares it either way.
- **"`Context access might be invalid` warnings."** Cosmetic — the VS Code Actions extension can't verify `vars.X`/`secrets.X` until the environment exists. Goes away once created.
- **"My `.deployignore` patterns aren't working."** The prune logic handles literal paths (with a `/`) and bare-name globs. It does NOT handle full gitignore semantics (`!` negations, `**/` deep globs). Keep patterns simple; if they need more, switch to `rsync --exclude-from`.

## Failure-case discussion

The most teaching-rich segment.

**`IGNITION_API_KEY` wrong on the environment** — Ship succeeds (docker cp doesn't care about the API), scan 403s; the workflow first assumes an unprepared gateway and does its one-time restart-retry, then the retry 403s again and the run exits non-zero. Files are on disk in the container but the gateway hasn't been told; runtime is stale. Recovery: fix the secret, re-run (`workflow_dispatch`); idempotent. Lesson: the verify step can't validate the key's *permissions* without a call, so the scan step is where you find out.

**Target container not running** — Verify step fails with "container is in state 'exited', expected 'running'". No-op, safe. Recovery: `docker compose up -d ignition-dev`, re-run. Lesson: fail fast at the right step; `docker cp` against a stopped container still writes to the volume, which desyncs on next start.

**Runner offline** — Workflow queues forever, no logs. Gateway unchanged. Recovery: `docker compose restart github-runner`. Lesson: self-hosted has operational cost — keep the runner alive across reboots and registration-token expirations.

**Partial ship (runner killed mid-`docker cp`)** — Some files new, some missing; gateway sees inconsistent state. Possibly broken (a view referencing a not-yet-landed script). Recovery: re-run; the wipe-then-copy converges on the working tree's state. Lesson: the strongest argument for image-based deploys (atomic) when the failure mode matters.

## Rollback discussion

The lab doesn't formally implement rollback. Three patterns:

1. **`git revert` on `main`** — idempotent; re-runs `deploy.yml`, restores **dev**.
2. **`release.yml` workflow_dispatch with an older tag** — the canonical "redeploy v0.1.0" for **prod**; works because every prod deploy is pinned to a tag.
3. **Snapshot before deploy** — take a `gwbk` first.

Maps to the branch: revert on `main` for **dev**; re-deploy the previous tag for **prod**.

## Stretch — gateway-level config & modules

1. **What ships:** the workflows `docker cp ./projects/.` and `./services/config/.`. But `services/modules.json` is a **sibling of** `services/config/`, *not under it*, so it is **not shipped** (it's bind-mounted into the gateways here). Confirm via the `docker cp` targets.
2. **What a scan can apply:** database connection JSON is scan-friendly; `modules.json` (module enablement) needs a gateway restart — the scan API can't reload module state.

Payoff (foreshadows Lab 05): file-based + scan is great for what changes daily (views, connections) but can't touch the gateway/module baseline — which is what image-based deploys own.

## Wrap-up

- Have them stop the **runner container only** if not continuing (`docker compose stop github-runner`). Nothing secret lingers in `.env` — the registration token was short-lived and minted by `gh` at setup time.
- Lab-05 (image-based) is the natural continuation — same stack, different deploy mechanism.
