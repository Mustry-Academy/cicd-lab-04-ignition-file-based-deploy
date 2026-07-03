# Ignition 8.3 file structure — cheat sheet

Reference reading for Block A. Everything Ignition stores on disk, organized by *who owns it* and *whether it belongs in git*.

## The three buckets

Everything inside an Ignition gateway's `data/` directory falls into one of three buckets:

| Bucket | What | Owner | In git? |
|---|---|---|---|
| **Project-level** | Per-project resources: views, scripts, tags, UDTs | The application (versioned, peer-reviewed) | **Yes** |
| **Gateway-level** | Cross-project config: DB connections, identity providers, tag history connections, enabled modules | The application (versioned, but smaller scope) | **Yes** |
| **Operational** | Runtime state: internal DBs, logs, temp, metadata, runtime users | The gateway (gateway owns this, full stop) | **No** |

The whole point of Block A is to internalize this split. If you can answer "which bucket?" for any file in `data/`, you'll know how to version, deploy, and roll back.

## The `data/` directory, top to bottom

What you'll see when you `ls /usr/local/bin/ignition/data` inside the container:

### `projects/`

Project-level. One subdirectory per Ignition project. A project's resources are
**namespaced by the module that owns them**: first the module, then the resource type, then the
name. The real shape (from the shipped [`example-project`](../projects/example-project/)):

```
projects/
└── <project-name>/
    ├── project.json                              ← descriptor: {title, description, enabled, inheritable, parent}
    ├── com.inductiveautomation.perspective/      ← Perspective module owns its resources
    │   ├── views/
    │   │   ├── pages/<PageName>/
    │   │   │   ├── view.json                      ← the view definition
    │   │   │   ├── resource.json                  ← per-resource manifest (scope, version, signature)
    │   │   │   └── thumbnail.png                  ← (pages only)
    │   │   ├── templates/<group>/<Name>/view.json
    │   │   └── common/<...>/view.json
    │   ├── page-config/
    │   └── session-props/
    └── ignition/                                 ← platform-owned project resources
        └── global-props/
        └── script-python/
```

The key 8.3 detail: **every resource folder carries a sibling `resource.json` manifest** next to its
payload (`view.json`, etc.). That manifest is what the gateway reads to track the resource — and since
the gateway rewrites it on every interaction (timestamps, signatures), this repo ships a normalized
diff driver plus `scripts/clean-ignition-resource-churn.sh` to undo the volatile-only rewrites.

This is the bread and butter of CI/CD for Ignition. The whole `projects/<name>/` directory is what the `deploy.yml` workflow ships onto the **dev** gateway (on push to `develop`) and what `release.yml` ships onto **prod** (on tag push from `main`) in Block B. On the **local** gateway it just sits there via bind mount — edit-and-scan, no copy step.

### `config/`

Gateway-level config. Shared across all projects. In 8.3 this is organized as
**`config/resources/<scope>/<module-id>/<resource-type>/<name>/{config.json, resource.json}`** —
scope-first, then namespaced by the owning module, just like project resources.

The **scopes** (in this repo, under [`services/config/resources/`](../services/config/resources/)):

| Scope | Purpose |
|---|---|
| `external` | Built-in Ignition defaults (the base everything inherits from). |
| `core` | The locally-managed, **portable** config you version and ship (DB connections, identity providers, tag providers, system properties). Inherits `external`. |
| `loc` / `dev` / `prd` | Per-environment overrides, selected at boot via `-Dignition.config.mode=<scope>`. Inherits `core`. |
| `local` | **Per-instance, instance-bound** state — see the `local/` note below. |

Real examples from `core/` in this repo:

```
config/resources/core/
├── config-mode.json                                          ← scope descriptor {title, parent: "external"}
├── ignition/
│   ├── system-properties/{config.json, resource.json}        ← singleton (no <name> level)
│   ├── database-connection/TimescaleDB/{config.json, resource.json}
│   ├── identity-provider/default/{config.json, resource.json}
│   └── tag-provider/MQTT Engine/{config.json, resource.json}
└── com.inductiveautomation.historian/
    └── historian-provider/TimescaleDB Historian/{config.json, resource.json}
```

`config.json` holds the actual settings; the sibling `resource.json` is the manifest the gateway
rewrites on every change (hence the churn-undo script). Resources here are *referenced* by projects but
defined gateway-wide. A view might query a database, but the connection lives in
`core/ignition/database-connection/<name>/`. Move a project to a new gateway and you'd port the
project; you'd also port the matching `core/` resources.

### Deployment modes (this is the 8.3 feature behind those scopes)

The `core` / `loc` / `dev` / `prd` scopes above are not a lab invention. They are Ignition 8.3's
**deployment modes** feature. A deployment mode lets you keep **one** configuration set that
contains the settings for *every* environment, and have the gateway pick the right variant at boot.
You define any modes you like (development, staging, production, or custom); the common case is just
dev and prod.

The mental model that makes it click: **the same resource name resolves to different settings per
mode.** A device named `PLC-01` can be a **simulator** in development and the **real Modbus device**
in production, under the same name, so your projects never change. A database connection keeps its
name but points at the dev database in `dev` and the prod database in `prd`. Because it is all one
config set, one gateway backup carries every environment's settings, and you stop tracking a pile of
per-gateway differences by hand.

On disk that is exactly what you see in this repo:

```
config/resources/
├── core/                                   ← shared baseline, inherited by every mode
│   └── ignition/database-connection/TimescaleDB/config.json
├── loc/  ignition/database-connection/TimescaleDB/config.json   ← local override
├── dev/  ignition/database-connection/TimescaleDB/config.json   ← dev override
└── prd/  ignition/database-connection/TimescaleDB/config.json   ← prod override
```

The **same** `database-connection/TimescaleDB` resource carries a **different `config.json` under
each mode**, all inheriting `core`. Each scope has a `config-mode.json` descriptor declaring its
parent (so `loc`/`dev`/`prd` inherit `core`, which inherits `external`). The gateway selects the
active mode at boot with `-Dignition.config.mode=<scope>`. A good way to *see* it: diff the local
and prod copies of the same connection.

```bash
diff services/config/resources/loc/ignition/database-connection/TimescaleDB/config.json \
     services/config/resources/prd/ignition/database-connection/TimescaleDB/config.json
```

Everything one mode does *not* override falls through to `core`. This is a platform feature, not
tied to any deploy strategy: it works the same whether you deploy by copying files (this lab) or by
baking an image (Lab 05).

### `modules.json`

Gateway-level. A list of which modules to enable. In this repo the source of truth is
[`services/modules.json`](../services/modules.json), bind-mounted to `data/modules.json` on the
`local` gateway.

```json
{"modules": ["com.inductiveautomation.perspective", "..."]}
```

Editing this file changes which modules the gateway loads — but unlike project/config resources,
this is **not** picked up by a scan; the gateway has to **restart** (see the table below).
Versioning it is good practice — it documents the gateway's dependency surface. Note it is a
sibling of `services/config/`, *not* under it, so the deploy workflows (which `docker cp`
`./services/config/.`) do **not** ship it.

### `modules/`

Gateway-level binaries. `.modl` files for each installed module.

- **In git?** Generally **no**. Modules are large binary artifacts. Pin module *versions* in a manifest (e.g., a separate `module-versions.txt`); install modules separately via your runner setup or a custom Docker image.
- For lab 04, the host bind mount on `modules.json` enables modules at startup; the gateway downloads/installs the matching `.modl` files automatically.

### `db/`

**Operational.** The internal SQLite database (`config.idb`, plus `autobackup/` copies). The gateway
is constantly reading and writing it — and it holds the **internal user store**: password hashes,
last-login timestamps, lockout state. There is no separate `users.idb` file; the user tables live
inside `config.idb`, which is one more reason this directory must never be committed. (A `gwbk`
backup carries the same data — keep those out of git too.)

- **In git?** Absolutely **no**.
- **Backup story?** Gateway-level backup (`gwbk` file), not git.

### `jar-cache/`, `metricsdb/`, `var/`

**Operational.** Runtime breadcrumbs: the launcher jar cache, the metrics store, module runtime
state. Note that gateway logs live *outside* `data/` entirely, at the install root
(`/usr/local/bin/ignition/logs/` in the container).

- **In git?** No.
- **Backup?** Often you don't even back these up — they're regenerable.

### `.resources/`, `migration-log-*.md`, `*.digest.json`

**Operational / generated.** Ignition's content-addressed blob store (`.resources/`, files named by
SHA-256), 8.3 migration logs, and theme/font/icon digests. The gateway regenerates these; they churn
constantly. All are excluded by [`.gitignore`](../.gitignore) — if you ever see them in `git status`,
something is wrong with your ignore rules.

### `config/resources/local/`

Per-instance, **instance-bound** state — *not* "mostly empty, ignore it." In this repo it holds the
OPC-UA client/server keystores (`com.inductiveautomation.opcua/{client,server}-keystore/`), the
gateway's UUID (`com.inductiveautomation.opcua/uuid/`), and `local-system-properties/`. These are
tied to *this specific gateway instance* and must **not** be copied across gateways — promoting them
would clone one gateway's identity onto another. Treat the `local` scope as belonging to the box,
like operational state, even though it lives under `config/`.

## The two questions to ask

For any file you see on a running gateway, ask:

1. **Would this file be different on a teammate's identical clone?** If yes → operational. If no → versionable.
2. **Would I want this file in git history?** If yes → versioned. If no → ignored / backed up some other way.

These two questions correctly classify ~99% of `data/` contents.

## Minimal example for the lab

Block A's "you do" suggests creating a project on disk manually if you don't have the Designer installed. In 8.3 a view must live under its owning module's namespace **and** carry a sibling `resource.json` manifest, or the gateway won't register it. Minimal viable structure:

```bash
mkdir -p "projects/sample/com.inductiveautomation.perspective/views/Hello"
cat > projects/sample/project.json <<'EOF'
{"title":"Sample","description":"Demo project for Block A","enabled":true,"inheritable":false,"parent":""}
EOF
cat > "projects/sample/com.inductiveautomation.perspective/views/Hello/view.json" <<'EOF'
{
  "custom": {},
  "params": {},
  "props": { "defaultSize": { "height": 600, "width": 800 } },
  "root": { "type": "ia.container.coord", "version": 0 }
}
EOF
cat > "projects/sample/com.inductiveautomation.perspective/views/Hello/resource.json" <<'EOF'
{"scope":"G","version":1,"restricted":false,"overridable":true,"files":["view.json"],"attributes":{}}
EOF
```

After triggering a project scan against the local gateway (`scripts/trigger-scan.sh projects --gateway local`), the `sample` project shows up in the gateway. It won't look like much — that's the point. (Note: `scope` `G` = gateway/global; the manifest is what makes the resource visible to the scan.)

## What changes when

Some changes require **only** a scan; others require a **restart**.

| Change | Scan only? |
|---|---|
| Add/modify a Perspective view | ✓ |
| Add/modify a project script | ✓ |
| Add/modify a tag UDT | ✓ |
| Add a database connection | ✓ (config scan) |
| Add/remove a module from `modules.json` | ✗ — needs restart |
| Change gateway memory (`-m` arg) | ✗ — needs restart |
| Change Java args | ✗ — needs restart |

The shipped `scripts/trigger-scan.sh` only handles the scan-able cases. For the restart cases, the deploy needs an extra step (`docker compose restart ignition-local` / `-dev` / `-prod` in the lab; `Restart-Service` or `systemctl restart` on a real host).

## Further reading

- [Inductive Automation Docker image docs](https://docs.inductiveautomation.com/docs/8.3/platform/docker-image/) — what the official image expects under `data/`
- [Ignition 8.3 Configuration files](https://docs.inductiveautomation.com/docs/8.3/configuration/) — official descriptions of resource files
- [Project resources](https://docs.inductiveautomation.com/docs/8.3/platform/projects/) — what's a project, what's a resource
