# Lab 04 — Ignition file-based deploy

Day 2 (afternoon) of the [CI/CD for Ignition Masterclass](https://github.com/mustry-academy/cicd-masterclass).

> Decode the Ignition 8.3 file structure, then build a file-based deploy pipeline that promotes project changes from a local working gateway, through a dev environment on push to `develop`, to a prod environment on a tag release cut from `main` — all with a hot scan, no gateway restarts. The pipeline follows **Git Flow**.

This is the **first lab that opens up the Ignition gateway itself**. Labs 02–03 already worked with a real Ignition project — a Perspective HMI and a couple of Python script libraries running on a gateway you spin up — but kept the gateway's *administrative* side (config, modules, databases, deploys) deliberately abstracted away: the repo tracked only project files, and the gateway generated its own config into a volume you never touched. This lab pulls that curtain back — the `data/` file structure, gateway-level config, and how to deploy it — and points it at three real gateways that simulate a local → dev → prod promotion flow.

Block C (image-based deploys) lives in [`cicd-lab-05-ignition-image-based-deploy`](https://github.com/mustry-academy/cicd-lab-05-ignition-image-based-deploy). Block D (multi-gateway) lives in [`cicd-lab-06-multi-gateway-deploy`](https://github.com/mustry-academy/cicd-lab-06-multi-gateway-deploy).

## Prerequisites

- A fork of this repo (the self-hosted runner registers against your fork, not the upstream)
- The [GitHub CLI](https://cli.github.com/) (`gh`), authenticated (`gh auth status`) — `setup.sh` uses it to mint the runner's short-lived registration token; no Personal Access Token to create or store (same as Lab 03)
- **≥ 8 GB free RAM for Docker** — three Ignition gateways each cap at 1 GB, plus TimescaleDB, the runner, and the usual Docker Desktop overhead
- _Optional but recommended:_ pass [`cicd-preflight`](https://github.com/mustry-academy/cicd-preflight) so unrelated env issues don't bite you mid-lab
- _Background reading:_ [Lab 03](https://github.com/mustry-academy/cicd-lab-03-github-actions) covers the GitHub Actions fundamentals this lab builds on, but this lab stands alone — the self-hosted runner ships in `docker-compose.yaml`, no manual `docker run` of `myoung34/github-runner` required

## Quick start

```bash
gh repo clone mustry-academy/cicd-lab-04-ignition-file-based-deploy
cd cicd-lab-04-ignition-file-based-deploy
cp .env.example .env
scripts/setup.sh    # brings up the stack, waits for all three gateways, prints credentials
```

Once setup finishes you have three Ignition gateways:

| Gateway | URL | Source of project files |
|---|---|---|
| `local` | http://localhost:8088 | Bind-mounted from `./projects/` and `./services/config/` — edits show up immediately |
| `dev` | http://localhost:8089 | Empty until `deploy.yml` runs on push to `develop` |
| `prod` | http://localhost:8090 | Empty until `release.yml` runs on tag push `v*` (cut from `main`) |

Login to any of them with the credentials from `.env` (`GATEWAY_ADMIN_USERNAME_LOCAL/_DEV/_PROD`, default `admin / password`).

> **Trial mode:** each gateway runs in 2-hour trial mode. Reset via *Gateway → Config → Licensing → Reset Trial* — unlimited and entirely legal for development. You'll do this **three times** if you keep all three gateways up long enough.

> **Stuck?** See [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md) for the common stack / runner / deploy failures and their fixes. Before opening a PR, run `scripts/validate.sh` (the quick JSON / `.deployignore` checks) and, if you set it up, `pre-commit run --all-files` (the yamllint / shellcheck / actionlint / ign-lint suite CI runs) — see `.pre-commit-config.yaml`.

## Lab structure

The lab is one exercise in two ordered parts — see [`exercises/lab.md`](./exercises/lab.md):

1. **Ignition 8.3 file structure decoded** — know every file in `data/`: what it is, who owns it, whether it belongs in git.
2. **File-based deploy mechanic** — ship project changes local → dev → prod, hot scan, no restarts.

> Image-based deploys and multi-gateway coordination come next, on Day 3, in separate labs ([image-based](https://github.com/mustry-academy/cicd-lab-05-ignition-image-based-deploy), [multi-gateway](https://github.com/mustry-academy/cicd-lab-06-multi-gateway-deploy)).

## Repo layout

```
cicd-lab-04-ignition-file-based-deploy/
├── README.md
├── docker-compose.yaml                 ← three Ignition gateways + TimescaleDB + bundled self-hosted runner
├── .env.example                        ← copy to .env before running
├── .deployignore                       ← what NOT to copy onto dev/prod gateways
├── .gitattributes                      ← JSON line-ending normalization + binary markers
├── .pre-commit-config.yaml             ← local git hooks: the same linters CI runs (carried from Lab 03)
├── .yamllint.yml                       ← yamllint config
├── .shellcheckrc                       ← lets shellcheck resolve the sourced scripts/lib.sh
├── rule_config.json                    ← ign-lint (Perspective view) rules
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                      ← PR validation: linters + JSON/.deployignore (ubuntu-latest, free)
│   │   ├── deploy.yml                  ← push to develop → dev gateway (self-hosted)
│   │   └── release.yml                 ← tag v* on main → prod gateway (self-hosted)
│   ├── actionlint.yaml                 ← declares the self-hosted `lab04` runner label
│   └── pull_request_template.md
├── exercises/
│   └── lab.md                          ← the lab, in two ordered parts
├── db-init/                            ← timescaledb initialisation: create ignition_dev and ignition_prd databases
├── docs/                               ← reference reading
│   ├── ignition-file-structure.md
│   └── file-based-deploy-pattern.md
├── instructor-notes/                   ← answer key (read after solo work)
│   └── lab-key.md
├── scripts/
│   ├── setup.sh                        ← bootstraps the whole stack
│   ├── teardown.sh                     ← stop the stack (with --volumes to wipe)
│   ├── scan.sh                         ← curl the scan API (any gateway via --gateway)
│   ├── lib.sh                          ← shared helpers
│   ├── clean-ignition-resource-churn.sh ← undo volatile-only resource.json rewrites (dry-run / --apply)
│   ├── git-diff/                       ← textconv normalizer that hides volatile metadata in diffs
│   └── git-hooks/                      ← skip-worktree hooks for the machine-local config file
├── projects/                           ← project content (bind-mounted into `local` only)
│   ├── example-project/                ← a real Perspective project (views, templates)
│   └── packaging-site/                 ← a second project; proves one deploy ships every project under projects/
├── services/
│   ├── config/                         ← gateway-level config (bind-mounted into `local`)
│   │   └── resources/                  ← <scope>/<module-id>/<resource-type>/<name>/{config.json,resource.json}
│   └── modules.json                    ← module enablement (shared by all three gateways)
├── third-party-modules/                ← bundled .modl binaries the gateways install at startup
└── tests/                              ← validation scaffold (see scripts/validate.sh)
```

## The Compose stack

Three Ignition 8.3 gateways + one TimescaleDB. The three gateways simulate the classic local → dev → prod promotion:

- **`ignition-local`** bind-mounts `./projects/` and `./services/config/` from the host. Anything you write into those paths on your laptop is *immediately on disk* inside the local gateway. Hit `scripts/scan.sh both` to make the gateway notice. That's the tight inner feedback loop.
- **`ignition-dev`** uses a named volume (not a bind mount). It starts empty; the deploy workflow (`deploy.yml`) `docker cp`s the working tree into the container and triggers a scan. Mirrors how a real shared dev environment gets fed by CI.
- **`ignition-prod`** is the same shape as dev, populated by the release workflow (`release.yml`) when you push a tag.

The single TimescaleDB hosts three logical databases (`ignition_loc`, `ignition_dev`, `ignition_prd`) so each gateway can have its own historian data without crosstalk.

Memory is set to 1 GB per gateway via Compose limits. Tight but workable; bump it in `docker-compose.yaml` if you see GC pauses.

## Branching model (Git Flow)

This lab uses **Git Flow**: two long-lived branches map to the two deployed gateways.

```
feature/*  ─┐
            ├─PR→  develop ──push→  deploy.yml ──docker cp + scan──→ DEV gateway
hotfix/* ─┐ │
          │ └── release/* ─PR→ main ──tag vX.Y.Z→ release.yml ──docker cp + scan──→ PROD gateway
          └────────────────────────┘
```

| Branch | Role | What CWe-does |
|---|---|---|
| `develop` | Integration — feature branches merge here | `deploy.yml` ships the working tree to the **dev** gateway |
| `main` | Release-ready — only `release/*` and `hotfix/*` merge here | nothing on its own; you **tag** `vX.Y.Z` to release |
| `feature/*` | Day-to-day work, branched off `develop` | `ci.yml` validates the PR into `develop` |
| `release/*` / `hotfix/*` | Stabilize a release / urgent fix, merged into `main` (and back to `develop`) | `ci.yml` validates the PR into `main` |

The `release/*` branch is your **freeze point**: cut it when `develop` is exactly what you want in prod, merge it into `main`, and tag. The tag — not the merge — is what `release.yml` ships, so prod always runs a named, re-deployable version.

> **Setup:** Git Flow needs a `develop` branch. Create it once in your fork
> (`git checkout -b develop && git push -u origin develop`) and, optionally, set it as the fork's
> **default branch** (*Settings → Branches*) so feature PRs target it by default.

## A note on the CI/CD workflows

Three workflows under [`.github/workflows/`](./.github/workflows/):

| File | Trigger | Runner | Purpose |
|---|---|---|---|
| [`ci.yml`](./.github/workflows/ci.yml) | PR to `develop` or `main` | `ubuntu-latest` (free) | Validate JSON, `.deployignore` syntax, and the workflow files themselves. |
| [`deploy.yml`](./.github/workflows/deploy.yml) | Push to `develop` (deploy paths only), manual | `[self-hosted, lab04]` | File-based deploy to the **dev** gateway via `docker cp`. |
| [`release.yml`](./.github/workflows/release.yml) | Tag `v*` (on `main`), manual | `[self-hosted, lab04]` | File-based deploy to the **prod** gateway. Same mechanics, different environment. |

> `deploy.yml` has a `paths:` filter (`projects/**`, `services/config/**`, `.deployignore`, `scripts/scan.sh`, `scripts/lib.sh`, `.github/workflows/deploy.yml`), so a push to `develop` that only touches docs or the README does **not** trigger a deploy — edit project or config content to see it fire.

Both deploy workflows need:

- The bundled self-hosted runner (`github-runner` service in `docker-compose.yaml`) registered against your fork with the `lab04` label. It auto-registers using a short-lived registration token that `setup.sh` mints with `gh`, and shares the host's Docker daemon (mounted `/var/run/docker.sock`) so the workflows can `docker cp` files into the dev/prod gateway containers. If you'd rather use your own runner instead, set `runner.labels` to include `lab04` and skip the bundled service.
- A GitHub **environment** per workflow with the right secret + variables:

| Scope | Name | Type | Purpose |
|---|---|---|---|
| Environment `lab-gateway-dev` (deploy.yml) | `IGNITION_API_KEY` | Secret | Token from the dev gateway with Project Scan + Config Scan permission |
| Environment `lab-gateway-dev` | `IGNITION_URL` | Variable (optional) | Defaults to `http://ignition-dev:8088` (bundled-runner case). Override to `http://localhost:8089` if your runner is on the host. |
| Environment `lab-gateway-dev` | `IGNITION_CONTAINER` | Variable (optional) | Defaults to `lab04-ignition-dev` |
| Environment `lab-gateway-prod` (release.yml) | (same three) | | Defaults: URL `http://ignition-prod:8088`, container `lab04-ignition-prod` |

Add **required reviewers** on the `lab-gateway-prod` environment if you want a manual approval gate on tag releases — common pattern, no workflow change required.

The deploy part of [`exercises/lab.md`](./exercises/lab.md) walks through the end-to-end setup.

## Licence

Apache 2.0 — see [`LICENSE`](./LICENSE).
