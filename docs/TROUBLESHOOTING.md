# Troubleshooting

Quick fixes for the things that bite people during Labs A and B. Work top to bottom; most issues
are one of the first three.

## The stack won't start / `scripts/setup.sh` fails

- **Docker isn't running or isn't Compose v2.** `docker compose version` must work (note the space —
  not `docker-compose`). Start Docker Desktop and re-run `scripts/setup.sh` (it's idempotent).
- **Not enough RAM.** Three gateways at 1 GB each + TimescaleDB + the runner need **≥ 8 GB free**.
  If gateways crash or never reach RUNNING, raise Docker's memory or bump the per-gateway limit in
  [`docker-compose.yaml`](../docker-compose.yaml).
- **Port already in use.** 8088/8089/8090 (gateways) or 5432 (TimescaleDB) taken by something else.
  Stop the other process or change the host port mappings in `docker-compose.yaml`.

## A gateway never reaches RUNNING

- Give it time — a cold JVM start can take 60–120 s per gateway. `setup.sh` polls up to ~240 s each.
- Check logs (note: use `docker logs`, the container name — *not* `docker compose logs`, which wants
  the service name):
  ```bash
  docker logs --tail 200 lab04-ignition-local     # or -dev / -prod
  ```
- **Trial expired.** Each gateway runs in 2-hour trial mode. After it lapses the gateway stops
  serving. Reset via *Gateway → Config → Licensing → Reset Trial* (unlimited, legal for dev).

## `git status` shows lots of `resource.json` changes

Ignition rewrites the `resource.json` manifests on every interaction, usually touching nothing
but volatile metadata (modification timestamp, actor, signature). That churn is **meant to be
visible** — real edits must show up in git — and it's undone, not hidden:

```bash
scripts/clean-ignition-resource-churn.sh          # dry run: lists volatile-only files
scripts/clean-ignition-resource-churn.sh --apply  # restores them from HEAD
```

Files with real content changes (and anything staged) are never touched by the script.
`git diff` already hides the volatile metadata: `scripts/setup.sh` wires a textconv driver
(`scripts/git-diff/normalize-ignition-resource-json.py`) via `.gitattributes`. If diffs still
show timestamp/signature noise, re-run `scripts/setup.sh`.

The one exception is the machine-local `local-system-properties/config.json` (system UID, trial
state — it belongs to this specific box). The hooks installed by `scripts/setup.sh` keep it
`skip-worktree` so it never dirties the tree. To intentionally change that seed file and commit it:
```bash
git update-index --no-skip-worktree <path>
# edit, commit, push — the next pull re-applies skip-worktree
```

## The self-hosted runner is offline / jobs queue forever

- Container up? `docker compose ps github-runner` and `docker logs lab04-runner` (look for
  *"Listening for Jobs"*).
- **Runner missing entirely?** `setup.sh` deliberately starts the stack without the runner when it
  couldn't mint a registration token (placeholder `RUNNER_REPO_URL`, or `gh` missing /
  unauthenticated). Fix the cause below, then **re-run `scripts/setup.sh`** — a plain
  `docker compose up` / `restart` won't help, because only `setup.sh` mints the token.
- **Restart loop with *"Invalid configuration provided for token"* in the logs?** Same cause: the
  runner started without a (valid) registration token. Registration tokens also expire after
  **1 hour**, so a stale one from an earlier `setup.sh` run fails the same way. Re-run
  `scripts/setup.sh` to mint a fresh one.
- `RUNNER_REPO_URL` in `.env` must point at **your fork**, not the upstream.
- `gh` must be installed and authenticated (`gh auth status`) so `setup.sh` can mint the
  registration token.
- In your fork: *Settings → Actions → Runners* should list it online with the `self-hosted, lab04`
  labels.
- Don't add `EPHEMERAL` to the runner's environment in `docker-compose.yaml` — the image treats
  **any** non-empty value (even `"false"`) as "enable ephemeral mode", which deregisters the runner
  after every job.

## The deploy 403s on the scan step

The `IGNITION_API_KEY` for that environment is missing, wrong, or under-scoped. Generate the key
**on the target gateway's own UI** (*Config → Security → API Keys*), scope it to **Project Scan +
Config Scan**, and set it as the `IGNITION_API_KEY` secret on the matching GitHub environment
(`lab-gateway-dev` / `lab-gateway-prod`). Keys are **per-gateway** — a dev key won't authenticate
against prod.

## The scan step 401s on a fresh gateway

The scan API only accepts tokens the gateway has **loaded** — and a deploy can't scan in its own
token, because the scan call already needs it (chicken-and-egg). On a gateway that never loaded the
committed `cicd` token, the first deploy copies everything to disk (token included) but the scan
401s: it *looks* like "the API key deployed but nothing else did". `scripts/setup.sh` prevents this
by pre-seeding the token into `gateways/dev/config` and `gateways/prod/config` **before** first
boot, and it self-heals: a probe that still 401s (e.g. the stack was started with plain
`docker compose up`, so the pre-seed never ran) makes it seed the token and restart that gateway.
**Fix: re-run `scripts/setup.sh`.** Don't hand-generate a replacement token in the gateway UI
without committing it — the next deploy wipes uncommitted tokens and you're back to 401.

## Locked out of dev/prod after a deploy (admin password rejected)

Historically this happened when a deploy shipped the repo's copy of
`config/resources/core/ignition/user-source/` — its `users.json` carries the **local** gateway's
admin password hash, so it overwrote the target's own admin user. The current workflows spare
`user-source/`, `identity-provider/`, and `security-properties/` in the wipe and `.deployignore`
keeps them out of the payload, so this shouldn't happen anymore. If you still hit it (e.g. an older working tree):

- **Full reset:** `scripts/teardown.sh --volumes`, then `scripts/setup.sh`. Nukes all gateway state.
- **Targeted:** stop the gateway, delete `gateways/<gw>/config/resources/core/ignition/user-source`,
  start it again — it recommissions the admin user from the `GATEWAY_ADMIN_*` values in `.env`.

## I merged my PR but nothing deployed (GitHub Flow)

This lab uses GitHub Flow — the branch decides the gateway:

- **Did your PR actually merge into `main`?** `deploy.yml` fires on pushes to `main`, and merging a PR is what produces that push. If the PR is still open (or merged into some other branch), nothing ships to dev.
- **Did the change touch a deploy path?** Confirm it hit `projects/**` or `services/config/**`; a docs-only push to `main` is filtered out by the `paths:` filter.
- **Is Actions enabled on your fork?** No enabled workflows means no runs at all. Check *Settings → Actions* on your fork.
- **Prod doesn't update on a `main` merge — that's intentional.** Prod is reached by **tagging**: `git tag vX.Y.Z && git push origin vX.Y.Z` fires `release.yml`.

## The deploy ran but my change isn't visible

- Are you looking at the right gateway? `local` = :8088, `dev` = :8089, `prod` = :8090.
- Did the scan return HTTP 200? `scripts/scan.sh` pretty-prints the response with a
  `lastScanTimestamp`. Files on disk without a successful scan = gateway hasn't reloaded.
- Module enable/disable (`services/modules.json`) needs a **restart**, not a scan:
  `docker compose restart ignition-dev`.

## Validate before you push

```bash
scripts/validate.sh    # JSON parse + .deployignore syntax + actionlint — mirrors CI
```

Still stuck? The instructor answer key ([lab-key.md](../instructor-notes/lab-key.md)) has a
deeper failure-mode walkthrough.
