# File-based deploy pattern — cheat sheet

Reference reading for the deploy part of the lab. The complete pattern in five steps, the tradeoffs vs image-based, and the failure modes.

## The pattern in five steps

```
┌───────────────┐    ┌────────────┐    ┌───────────┐    ┌────────────┐    ┌────────┐
│ 1. Commit     │ →  │ 2. Check   │ →  │ 3. Prune  │ →  │ 4. Ship    │ →  │ 5.     │
│    to git     │    │    out on  │    │    per    │    │ files into │    │ Trigger│
│               │    │    runner  │    │ .deploy-  │    │ gateway    │    │ scan   │
│               │    │            │    │ ignore    │    │ container  │    │ API    │
└───────────────┘    └────────────┘    └───────────┘    └────────────┘    └────────┘
```

1. **Commit** to `projects/<name>/` or `services/config/` in git — on a `feature/*` branch, PR'd into `main` (see *GitHub Flow* below).
2. **Check out** the repo on the self-hosted runner or the runner hosted by Github.
3. **Prune** the working tree per `.deployignore` — exclude lab files, READMEs, secrets, anything that shouldn't reach the gateway.
4. **Ship** the files into the target gateway's container. How depends on the gateway:
   - **`local`** uses a bind mount on `./projects/` and `./services/config/`, so the files are already on disk inside the gateway. No copy step needed.
   - **`test` / `production`** bind-mount `./gateways/test/{projects,config}` and `./gateways/production/{projects,config}` (gitignored, created by `setup.sh`); the rest of their `data/` stays in named volumes. The runner is itself a container and doesn't share those host paths, so the workflows still `docker exec ... rm -rf` to wipe the destination (`projects/` and `config/`, sparing the five entries `.deployignore` protects — `config/local/`, `config/resources/local/`, and the gateway-owned internal identity by name: `config/resources/core/ignition/user-source/default/`, `user-source/opcua-module/`, and `identity-provider/default/`; other user sources and identity providers in those dirs are repo-owned and ARE wiped), then `docker cp` the working tree in. This wipe-then-copy gives you "deleted in repo → deleted in gateway" semantics that `rsync --delete` would have given you with a bind mount. The bind mounts pay off on the verification side: `ls gateways/test/projects` on the host shows exactly what a deploy shipped.
5. **Trigger** a project + config scan via `POST /data/api/v1/scan/{projects,config}` with that gateway's API key. The workflows self-heal here: if the scan comes back 401 (the gateway never loaded the API token) or 403 (first-boot commissioning reset the permissions), they restart the gateway once — the Ship step already put the token and `security-properties` on its disk, and the gateway loads them at boot — wait for RUNNING, and retry. So the first deploy to a fresh gateway is green; every later deploy hot-scans with no restart.

That's it. No SSH, no SCP, no remote shell. The gateway has an HTTP API that picks up disk changes.

## GitHub Flow: which branch ships where

This lab wires the pattern to **GitHub Flow**, so a branch — not a manual run — decides which gateway gets the files:

```
feature/* ─PR→ main ──push→ deploy.yml ──→ TEST gateway
              main ──tag vX.Y.Z→ release.yml ──→ PRODUCTION gateway
```

- **`main`** is the single long-lived branch. Merge a `feature/*` PR into it and `deploy.yml` ships the working tree to **test**. This is the fast inner loop — many small merges a day.
- There is no second long-lived branch: `main` also carries production. Merging ships *nothing* to production by itself; you **tag** `vX.Y.Z` on `main` and that tag fires `release.yml` to **production**.
- The tag is what production runs, so every production deploy is a named, re-deployable version — that's what makes the `workflow_dispatch` rollback (re-deploy an old tag) work. The TAG is your freeze point: tag the commit on `main` you want in production.

The `local` gateway sits outside GitHub Flow entirely — it's your bind-mounted scratchpad (edit-and-scan, no branch, no PR).

## Why this works (and why people get it wrong)

**Why it works:** Ignition watches its `projects/` and `config/` directories. When you POST to the scan endpoints, the gateway reads the disk and reconciles its in-memory state. For most changes — views, scripts, tags, datasource config — there's no restart needed. The gateway hot-reloads.

**Where people get it wrong:**

- **Copying without wiping first.** If you delete a view from your repo and just `docker cp ./projects/. <container>:...`, the old view file stays in the container and the gateway happily keeps serving it. The lab workflows wipe with `docker exec ... rm -rf` before copying. Skip that step at your peril.
- **Not pruning lab files.** Without `.deployignore`, your `README.md` ends up at `<gateway>/data/projects/<name>/README.md` — harmless, but accumulates noise. Lab files like `tests/` could be more dangerous (they might shadow real Ignition resources).
- **Forgetting the scan.** The files are on disk inside the container but the gateway hasn't noticed. Symptom: "my change isn't picked up; the file is right there." Solution: hit the scan endpoint.
- **Triggering a scan when a restart is what's needed.** Module changes, Java args, memory limits — these need a restart, not a scan. See the table in [`ignition-file-structure.md`](./ignition-file-structure.md).
- **Wrong API key for the wrong gateway.** Each lab gateway has its own API key. `IGNITION_API_KEY_LOCAL` won't authenticate against `ignition-test`. The workflow's environment-scoped secrets get this right automatically; manual `scan.sh` calls need the matching `--gateway` flag.
- **Partial copies.** If the runner crashes between copying view A and view B, the gateway scans a half-state and may serve broken views. Two-phase mitigations exist (write to a staging dir, then atomically swap) but for most labs, "fix forward by re-running the deploy" is fine.

### Never deploy the *internal* identity — external identity resources are config

The precise rule is narrower than "never deploy identity". What must never ship is the **gateway-owned internal identity**, by name: `config/resources/core/ignition/user-source/default/` (plus `user-source/opcua-module/`) and `identity-provider/default/`. Those are what first-boot commissioning creates, and `user-source/default/users.json` carries *that* gateway's admin password hash. Deploy one gateway's copy onto another and you overwrite the target's admin user with the source's — if the source hash isn't the password you expect, you're locked out of the gateway, and only wiping its volumes brings it back. (This happened in a previous course run: the repo committed the *local* gateway's user source, so the first production deploy locked everyone — students and instructor — out of production.) The wipe side is just as dangerous: deleting `users.json` out from under a *running* gateway breaks logins the instant the deploy runs, no restart required. This lab keeps the internal-identity dirs untracked in git, lists them in `.deployignore`, and the workflows' wipe spares them by name.

Everything *else* identity-related is ordinary deployable config — and in real projects you **do** deploy it. A database or AD user source, a SAML/OIDC identity provider: these hold no password data (the users live in the external system), so they are tracked, deployed, and wiped like any other resource. The same goes for `security-properties/`: it is permission *policy* (APIToken scan grants, designer/config permissions), and this lab commits and deploys it. That's safe because the committed copy points `systemAuthProfile` at `default`, which exists on every gateway — commissioning creates the `default` user source everywhere. Two supporting mechanisms keep it that way: `scripts/setup.sh` stashes the committed `security-properties` aside during the *local* gateway's very first boot (otherwise commissioning, finding a security-properties without a matching user source, invents a `temp_N` identity and rewrites the file to point at it), lets commissioning create `default`, then restores the file and restarts local; and `scripts/teardown.sh --volumes` also deletes the local gateway's gitignored internal-identity dirs, so a wiped stack recommissions cleanly, like a fresh clone. The design rule: **wipe = repo-owned; preserve = whatever `.deployignore` prunes.**

## File-based vs image-based: when each fits

| Concern | File-based | Image-based |
|---|---|---|
| Time to deploy | Seconds (cp + API call) | Minutes (build → push → pull) |
| Hot reload? | Yes, for project changes | No (container restart) |
| Atomic rollback | Hard (re-deploy old state) | Easy (run the previous image tag) |
| Module changes | Hard (gateway restart needed) | Trivial (bake into image) |
| Multi-environment promotion | Manual per env | Tag, promote, done |
| Runner requirements | Docker daemon access (or filesystem access for bind-mount setups) | Registry access only |
| Best for | Active development, frequent project changes | Production, immutable releases |

File-based shines when you're iterating on a project — Perspective views, scripts, tags. You can be deploying every five minutes. Image-based shines when you're shipping a release — every change goes through a build that produces a versioned, signed artifact.

Most mature Ignition deployments end up using **both**: image-based for the gateway+modules baseline (the image you'd boot a fresh server with), file-based for project content (what changes daily). Lab 04 covers file-based; the image-based companion lab covers the other half.

## API key scopes

Each gateway has its own API key. At minimum each one needs:

- **Project Scan** — to authorize `POST /data/api/v1/scan/projects`
- **Config Scan** — to authorize `POST /data/api/v1/scan/config`

You'll see other scopes in the API Keys UI (Backup, Gateway Network, Tag Read/Write, …) — *don't grant them*. The deploy runner shouldn't be able to back up the gateway or write tags. Principle of least privilege.

In the lab the keys live in `.env` (for manual scripts) as `IGNITION_API_KEY_LOCAL/_TEST/_PRODUCTION` — generated per clone by `scripts/setup.sh`, never committed — and as environment-scoped GitHub secrets named `IGNITION_API_KEY` on the `lab-gateway-test` / `lab-gateway-production` environments (for CI). A key belongs in exactly two places: the secret store that uses it and the gateway that checks its hash — never in git, where it would be a working credential in every clone and every fork, forever (history doesn't forget). If the same runner ever needs more capability (e.g. take a backup before deploy), generate a separate key for that — don't reuse.

## Rollback

Three patterns, in increasing order of operational maturity:

1. **`git revert` / `git reset` + re-deploy.** The deploys are idempotent; reverting a bad PR and pushing again restores the test gateway. Most cohorts start here. Works for most cases.
2. **Tagged deploys + re-deploy a known-good tag.** This lab's `release.yml` is built for this: `workflow_dispatch` takes a tag as input, so re-deploying `v0.1.0` to production is two clicks in the GitHub UI. Lab 05 extends this pattern across multiple gateways.
3. **Snapshot before deploy.** A mature workflow would take a `gwbk` of the gateway *before* copying, so rollback is "restore the backup." This lab's workflows do **not** do this (their steps are checkout → verify → prune → `rm -rf` + `docker cp` → scan → smoke-check); it's the heaviest pattern, only worth it for high-stakes deploys, and is left as a stretch. Lab 07 covers gateway backups properly.

Lab 04 ships patterns 1 and 2 (the latter as a hand-cranked workflow_dispatch); pattern 3 is left as a stretch.

## Self-hosted runner topology

For the file-based pattern to work, the runner needs **a way to write to the target gateway's `data/` directory**. There are three realistic topologies; this lab uses two of them across its three gateways.

### A) Runner on host, gateway bind-mounts from host (used for `local`)

```
host
├── lab04-runner       ← runner has the repo working tree
└── lab04-ignition-local ← gateway bind-mounts ./projects + ./services/config
   from the same repo path
```

Cheap, no network, no auth headaches. Edit a file in the repo, hit scan, done. This is what `local` does. It's the right pattern for fast inner-loop iteration.

### B) Runner on host, gateway on remote VM, NFS

```
runner-host           ───nfs mount───▶  remote-gateway-host
└── /mnt/gateway-data/                  └── /var/lib/ignition/data/
```

Common for real-world deployments. The NFS share is the filesystem boundary. Not used in this lab, but the most common production pattern.

### C) Runner with docker socket, gateway in another container (used for `test` and `production`)

```
lab04-runner   ───/var/run/docker.sock───▶  Docker daemon
                                                │
                                                ▼
                                       lab04-ignition-test  (or -production)
   `docker exec ... rm -rf <data-path>` then `docker cp` writes into the container's filesystem
   (landing in the `./gateways/<gw>/` bind mounts, visible from the host)
```

The bundled `github-runner` in `docker-compose.yaml` uses this for `test` and `production`. Mounting the docker socket gives the runner full daemon access (lab-grade, not production-grade — in production you'd use a remote registry or a constrained API). The runner ships through the socket because it's a container itself and doesn't share the host filesystem. test/production's `projects/` and `config/` *are* bind-mounted to `./gateways/<gw>/` on the host — deliberately, so a deploy is observable: `cat gateways/production/config/resources/core/ignition/database-connection/TimescaleDB/config.json` shows exactly what CI shipped. Treat those host dirs as read-only in practice; editing them by hand defeats the pipeline.

## When to NOT do file-based

A few situations where file-based is the wrong tool:

- **Air-gapped / one-way networks.** If the gateway can't accept a scan API call (no incoming connections allowed), file-based doesn't work. Use image-based with a registry pull instead.
- **Strict change windows.** If your team needs to deploy atomically with a clear rollback button, image-based + container restart wins.
- **Multi-version coexistence.** If you need v1.4 and v1.5 of a project to both be deployable simultaneously (canary), file-based gets awkward. Use per-project naming or image-based.

Most Ignition shops never hit any of these. File-based is the right default for ~80% of deploys.
