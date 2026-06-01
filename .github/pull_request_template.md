<!--
Mustry Academy — PR template
Keep it short; the goal is to make the reviewer's job easy.
-->

## What

<!-- One or two sentences describing what this change does. -->

## Why

<!-- Why are we making this change now? Link any related issue or discussion. -->

## How to test

<!-- Specific commands or steps the reviewer can run. -->

## Checklist

- [ ] Local validation passes (`scripts/validate.sh` — JSON, `.deployignore`, actionlint; mirrors CI)
- [ ] Compose stack still starts cleanly (`docker compose up -d` → `curl -fsS http://localhost:8088/StatusPing` returns `RUNNING`; dev is `:8089`, prod `:8090`)
- [ ] No secrets committed (`.env` stays local)
- [ ] Changes are scoped to one logical thing
