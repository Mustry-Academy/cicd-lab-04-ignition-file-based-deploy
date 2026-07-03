# Block A — Ignition 8.3 file structure decoded

**Duration:** ~90 minutes
* 15 min demo
* 15 min we-do (marker + find-newer)
* 15 min we-do ("everything is a file" tour: connections, tags, deployment modes, CSS)
* 25 min you-do
* 15 min debrief
* ~5 min buffer

## Goal

You should leave this block able to:

- Navigate an Ignition 8.3 gateway's `data/` directory and name what each top-level item is for
- Explain the difference between **project-level**, **gateway-level**, and **operational** state
- Predict which files appear on disk when you make a given change in the gateway UI
- Decide which of those files belong in git and which don't

## Pre-flight

```bash
cp -n .env.example .env
docker compose up -d
# Wait ~60s for the gateway to come up, then:
curl -fsS http://localhost:8088/StatusPing
```

Open <http://localhost:8088> (the `local` gateway — the one you'll work with for Block A) in your browser. Login: `admin` / `lab04password` (or whatever you set as `GATEWAY_ADMIN_PASSWORD_LOCAL` in `.env`). Dev and prod gateways (`:8089` / `:8090`) come up too but stay empty until Block B.

If you'd like to read ahead: [`docs/ignition-file-structure.md`](../docs/ignition-file-structure.md).

## We-do (20 min)

The instructor walks through the gateway's `data/` directory live, both from the inside (via `docker exec`) and from the outside (the host bind mounts).

```bash
docker exec -it lab04-ignition-local bash -lc "ls /usr/local/bin/ignition/data"
```

Tour, in order:

1. **`projects/<name>/`** — project-level state. One directory per project. Inside: `project.json` + module-namespaced resource folders, e.g. `com.inductiveautomation.perspective/views/pages/<Page>/{view.json, resource.json}` and `ignition/`. *This is the thing you'll deploy via file-based CI/CD.*
2. **`config/resources/<scope>/`** — gateway-level config, organized scope-first (`core`, `loc`/`dev`/`prd`, `local`) then by module: `core/ignition/database-connection/<name>/`, `identity-provider/<name>/`, `tag-provider/<name>/`. Shared across all projects.
3. **`config/`** root — gateway-level non-resource config (small).
4. **`modules.json`** — which modules the gateway has enabled. Gateway-level. (Repo source: `services/modules.json`.)
5. **`modules/`** — the actual installed module binaries (`.modl` files). Almost never committed to git; usually managed separately.
6. **`db/`** — the internal SQLite DB (`config.idb`), which includes the internal user store (password hashes, lockout state). **Operational state.** Never commit.
7. **`jar-cache/`, `metricsdb/`, `var/`, `.resources/`** — runtime / generated stuff (the last is Ignition's content-addressed blob store). Never commit. (Gateway logs live outside `data/`, at the install root.)

The instructor sketches the three-bucket model:

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

## We do (20 min)

Following along on your own gateway:

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
6. In the gateway UI, **Config → Databases → Connections → New**. Add a Postgres datasource pointing at host `timescaledb`, port `5432`, db `ignition_loc`, user/password from your `.env` (`POSTGRES_USER` / `POSTGRES_PASSWORD`, default `ignition` / `ignition`). Save. The hostname `timescaledb` is the compose service name — the local gateway resolves it on the lab's docker network.
7. Repeat step 4 (re-touch the marker first) — find the new files. The connection lands at `config/resources/<scope>/ignition/database-connection/<name>/config.json`. Gateway-level or project-level?

## We do: "everything is a file in git" (the guided tour)

The point of this section: prove that the things people assume live "inside Ignition somewhere" are all plain files you can read, diff, and commit. Do these from the repo root on your host (no gateway needed, these are already on disk under `services/` and `projects/`).

1. **Every database connection is a file.** Open `services/config/resources/core/ignition/database-connection/TimescaleDB/config.json`. This is the whole connection: JDBC URL, pool sizes, the (encrypted) password. Nothing hidden in a gateway database.

2. **Every PLC / device connection is a file.** Open `services/config/resources/core/com.inductiveautomation.opcua/device/Simulator/config.json` and `.../ignition/opc-connection/Ignition OPC UA Server/config.json`. The lab ships a **simulator** device on disk; in a real plant this same file would describe your Modbus / OPC-UA PLC. Point being: your PLC wiring is version-controlled, reviewable config, not clicks in a UI.

3. **Tags are files too.** Open `services/config/resources/core/ignition/tag-definition/example-tags/tags.json` (and `udts.json` for the UDT definitions). Tag providers, tags, and UDTs all serialize to JSON on disk. (Note the runtime *values* live in `services/config/ignition/tags/valueStore.idb`, which is operational and never committed, the definitions are, the live values are not.)

4. **Deployment modes: one config set, many environments.** This is an Ignition 8.3 platform feature, not a lab trick. The scopes you saw (`core`, `loc`, `dev`, `prd`) are **deployment modes**: the same resource name resolves to different settings per mode, and the gateway picks the mode at boot with `-Dignition.config.mode=<scope>`. See it directly:
   ```bash
   diff services/config/resources/loc/ignition/database-connection/TimescaleDB/config.json \
        services/config/resources/prd/ignition/database-connection/TimescaleDB/config.json
   ```
   Exactly one line differs: the `connectURL` points at `ignition_loc` vs `ignition_prd`. Same connection *name*, same everything else (that falls through to `core`), one per-mode override. The real-world version of this: a device named `PLC-01` is a **simulator in dev** and the **real device in prod**, under one name, so your project code never changes. One gateway backup carries every mode.

5. **Where is the CSS "hidden"?** In Perspective, styling lives in a few honest places, all of them files:
   - **Inline component styles** live right in the view: open `projects/example-project/com.inductiveautomation.perspective/views/pages/refrigeration/view.json` and find the `style` props on components.
   - **Style classes** (reusable named styles, the closest thing to a CSS class) are a *project resource* under `com.inductiveautomation.perspective/style-classes/<name>/` when a project defines them. This repo styles inline, so it has none, but that is where they land.
   - **Themes** (the gateway-wide look) are gateway-level theme CSS the gateway generates under `data/` (you saw `theme/font/icon digests` in the operational churn). Theme *authoring* files, when you customize a theme, are gateway config.

   The takeaway: there is no secret CSS store. It is inline in views, or a style-class resource, or a gateway theme file, all readable, all diffable.

## You do (30 min)

Solo. Make a series of changes in the gateway UI and answer: **which bucket is each in, and where does it live on disk?**

Pick three changes from this list (or invent your own). For each note:

- **What you changed** (one sentence)
- **Where it lives on disk** (path relative to `data/`)
- **Bucket**: project-level / gateway-level / operational
- **One sentence: would you commit this to git?**

> This repo ships **two** projects under `projects/`: `example-project` and `packaging-site`. As you make changes, notice that each project is a self-contained directory, and that the gateway config (connections, tags, deployment modes) is **shared** across both. That split, per-project resources vs one shared gateway config, is the whole point of the project-level vs gateway-level buckets.

Suggested changes:

1. Add a **Perspective view** to one of the two projects. Simulate on disk by creating `projects/packaging-site/com.inductiveautomation.perspective/views/pages/<Name>/{view.json, resource.json}` with the minimal 8.3 content from [`docs/ignition-file-structure.md`](../docs/ignition-file-structure.md). Note the `resource.json` manifest is required in 8.3, and that this lands under *one* project only, unlike a gateway resource.
2. Change the **gateway timezone** (Config → System → Time)
3. Add a **new user** to the gateway (Config → Security → Users)
4. Add a **new tag provider** (Config → Tags → Realtime Tag Providers)
5. Enable a **new module** (toggle a module in Config → Modules)

## Definition of done

You're finished with Block A when you can, without peeking:

- [ ] List the top-level `data/` entries and say which **bucket** each is (project / gateway / operational).
- [ ] Make a UI change and **find the file it wrote** on disk with the `/tmp/marker` + `find -newer` trick.
- [ ] State the real 8.3 path shape for a view (`projects/<x>/com.inductiveautomation.perspective/views/...` + `resource.json`) and a config resource (`config/resources/<scope>/<module>/<type>/<name>/config.json`).
- [ ] Point at the on-disk file for a database connection, a PLC/device connection, and a tag definition, and explain why "it's all in git" follows.
- [ ] Explain **deployment modes** in one sentence (one config set, per-mode overrides selected at boot) and name what differs between the `loc` and `prd` `TimescaleDB` connection.
- [ ] Explain why `db/` and `.resources/` must **not** be committed.

## Stretch challenge `[OPTIONAL]`

Draft a starter `.gitignore` for an Ignition project repo. Include patterns for the **operational** bucket (the internal DB, tag value stores, caches, blob stores). Compare with the shipped [`.gitignore`](../.gitignore). What did you miss? What did the shipped one miss?

This is the precursor to `.dockerignore` (lab-04-image-based) and `.deployignore` (Block B of *this* lab — already shipped in the repo for you to study).

## Debrief (15 min)

- What surprised you about the on-disk layout?
- Which bucket has the trickiest deploy story? (Hint: it's the one that *sometimes* needs a restart.)
- For your current customer's CI/CD: where does each bucket live, and which are versioned?
- What's the smallest atomic change you could meaningfully deploy? (This frames Block B.)
