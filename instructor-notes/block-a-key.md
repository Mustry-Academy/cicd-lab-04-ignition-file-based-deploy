# Block A — instructor answer key

> **Do not read this before you've attempted the You-do solo.** The classification skill is the lesson; if you peek you'll memorize answers instead of building the mental model.

## Block goal recap

By the end of Block A, participants should be able to answer the question *"Which bucket, and where on disk?"* for any change they make in the gateway UI. The three-bucket model (project-level / gateway-level / operational) is the central artifact.

## Classification reference

The We-do and You-do exercises pick from a list of typical gateway changes. Here's the answer key for each:

All paths are the real 8.3 layout: project resources are namespaced by owning module, and config
resources are `config/resources/<scope>/<module-id>/<resource-type>/<name>/{config.json, resource.json}`.
(Scope is usually `core` for portable config.) Tell learners to expect a longer `find` result than an
8.1-style flat path.

| Change | Bucket | On-disk path | In git? |
|---|---|---|---|
| Create a new Perspective view in project X | Project-level | `data/projects/X/com.inductiveautomation.perspective/views/<group>/<Name>/{view.json, resource.json}` | Yes |
| Add or modify a script library in project X | Project-level | `data/projects/X/ignition/script-python/<library>/` | Yes |
| Add a UDT / tag definition | Gateway-level | tag config under the tag provider: `config/resources/core/ignition/tag-provider/<name>/` | Yes |
| Change a project's title/description | Project-level | `data/projects/X/project.json` | Yes |
| Change gateway timezone (Config → System → Time) | Gateway-level | under `config/resources/core/ignition/system-properties/config.json` (or a sibling resource; path may shift between 8.3 minor versions) | Yes — but often in gitignore and set via env |
| Add a database connection | Gateway-level | `data/config/resources/core/ignition/database-connection/<name>/config.json` | Yes |
| Add a historian connection | Gateway-level | `data/config/resources/core/com.inductiveautomation.historian/historian-provider/<name>/config.json` | Yes |
| Add a new identity provider (OIDC) | Gateway-level | `data/config/resources/core/ignition/identity-provider/<name>/config.json` | Yes |
| Enable / disable a module | Gateway-level | `data/modules.json` (repo: `services/modules.json`) | Yes |
| Install a new module (.modl) | Gateway-level binary | `data/modules/<module>.modl` | Yes / No |
| Add a new gateway user (UI-managed) | Operational | inside `data/db/config.idb` (the internal user store — there is no separate `users.idb`) | **No** |
| Change the gateway admin password | Operational | inside `data/db/config.idb` | **No** |
| Tag values changing at runtime | Operational | `data/config/ignition/tags/valueStore.idb` (masked by `.gitignore`) | **No** |
| Wrapper logs filling up | Operational | `logs/` at the install root (outside `data/`) | **No** |

If a participant classifies something incorrectly, walk them through the two questions:

1. *Would this file be different on a teammate's identical clone?* If yes → operational.
2. *Would I want this in git history?* If yes → versioned.

These two questions handle ~99% of cases.

## Common stumbles

- **"I added a user in the UI — where did it land, and should I commit it?"** It landed inside the internal SQLite DB (`data/db/config.idb`) — there is no separate `users.idb` file. Never commit `db/`: the internal user tables in there hold hashed passwords, last-login timestamps, lockout state, and a `gwbk` backup carries the same data. The right pattern for source-controlled users is an identity provider (`data/config/resources/core/ignition/identity-provider/<name>/`), which gives you SSO and group sync.

- **"Why isn't `modules/` in git?"** Because `.modl` files are 5-100 MB binary blobs and they're keyed by license/vendor. Pin versions in a manifest; install separately. (Lab-04-image-based revisits this in the context of derived Docker images.)

- **"I changed the timezone in the UI but I can't find the file."** Sometimes the path is config-mode dependent — and Ignition 8.3 has shifted some config from XML to JSON across minor releases. The `docker exec lab04-ignition-local find /usr/local/bin/ignition/data/config -newer /tmp/marker -type f` trick handles this: the file *will* be newer than the marker, regardless of which precise path it's at. **Prerequisite:** the marker only works if they ran `docker exec lab04-ignition-local touch /tmp/marker` *before* the UI change (it's step 2 of the We-do). If they forgot, just re-touch the marker and redo the change. Expect the change to also rewrite a sibling `resource.json` — that's the gateway's manifest, not your edit.

- **"I made a Perspective change in the Designer but nothing's on disk yet."** Did they *save* in the Designer? Unsaved changes live only in the Designer's memory. The classroom symptom is "I see the change in the Designer preview but the file isn't there."

## Notes on the docker-compose lab gateway specifically

The lab runs three gateways but **Block A is all about `local`**. The `local` gateway is the only one that uses **host bind mounts** for `projects/` and `services/config/`:

- Any file you put in `<repo>/projects/sample/` is *immediately* at `<gateway>/data/projects/sample/` — no `docker cp` needed.
- Anything the local gateway writes to those paths (e.g., resource files from UI-driven changes) shows up *on your host*. Demonstrate this live: make a UI change, then `ls projects/` on the host. The new file is right there.

The `data/db/`, `data/jar-cache/`, `data/metricsdb/`, `data/var/` paths stay inside the named volume `ignition-local-data:` — students don't see them by default. If asked, `docker exec lab04-ignition-local ls /usr/local/bin/ignition/data/` shows the full tree.

The `dev` and `prod` gateways (`lab04-ignition-dev`, `lab04-ignition-prod`) use **named volumes for everything** — no bind mount on `projects/` or `config/`. That's deliberate: it matches how a real shared dev/prod environment works (you don't edit project files directly on the host; you ship them via CI). Block B is where students touch those. For Block A, leave them be.

## You-do grading

Strong "you do" notes have:

- **A real change made in the UI** (not just classified hypothetically).
- **The actual on-disk path**, not "somewhere in `config/`."
- **An explicit bucket**: project / gateway / operational.
- **A clear in-git decision** with reasoning ("yes — this is gateway-level config that all teammates need" or "no — this is per-instance state").

A "you do" that just lists three predefined answers from this key doesn't earn the block. Push them to make at least one change of *their own* choosing.

## Stretch — `.gitignore` for a real Ignition repo

Reasonable answer:

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

# Module binaries — manage separately
data/modules/*.modl

# Gateway backup files
*.gwbk

# Compose local-only files
.env
```

Things commonly missed:

- `data/config/local/` and `data/config/resources/local/` (per-instance identity: keystores, UUID)
- `data/config/ignition/tags/*.idb` (tag value stores hiding inside the versioned config tree)
- Backup files (`*.gwbk`)
- Module binaries (`*.modl`) — most participants will leave these in unless prompted

## Debrief crib

- **"What surprised you?"** Common answer: that so much is *operational*, not config — and that the user store (password hashes included) rides inside `db/config.idb` and every `gwbk`, which regularly end up in git without anyone realising.
- **"Which bucket has the trickiest deploy?"** Gateway-level. Some changes hot-reload via scan; others need restart. The participant who notices this is set up well for Block B.
- **"Smallest atomic change?"** A single view's JSON file. ~1 KB. Block B will deploy exactly this kind of change end-to-end.

## Wrap-up — set up Block B

Before students leave Block A:

- Remind them Block B uses the bundled `github-runner` container — they need a GitHub PAT (`repo` scope) in `.env` as `RUNNER_GITHUB_PAT` and `RUNNER_REPO_URL` pointed at their fork. `docker compose up -d github-runner` (or a `docker compose restart github-runner` after editing `.env`) brings it online.
- Have them generate an API key in each gateway UI now (local first, dev/prod can wait until they boot those). Store in `.env` as `IGNITION_API_KEY_LOCAL/_DEV/_PROD` and as environment-scoped secrets on the `lab-gateway-dev` and `lab-gateway-prod` GitHub environments.
- Verify all three gateways (`docker compose ps`) are running. If they tore down, Block B starts cold.
- Have them create the Git Flow `develop` branch in their fork now (`git checkout -b develop && git push -u origin develop`) — Block B deploys on merges into `develop`, and a missing branch is the #1 "nothing deployed" stumble.
