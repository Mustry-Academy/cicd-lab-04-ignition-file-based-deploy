#!/bin/bash
# One-shot setup for the lab 04 stack:
#   - sanity-checks the host (docker compose v2, curl, WSL quirks)
#   - installs the repo's git hooks (skip-worktree for the machine-local
#     Ignition config file) and a diff driver that hides volatile resource.json
#     metadata; volatile-only churn is undone with
#     scripts/clean-ignition-resource-churn.sh
#   - ensures .env is in place
#   - brings up the stack (three Ignition gateways + shared TimescaleDB)
#   - waits for ALL THREE gateways to become RUNNING
#   - triggers an initial projects + config scan against the LOCAL gateway
#     (only if its API key in .env is real, not the example placeholder).
#     Dev and prod start empty by design — they get populated by the deploy
#     and release workflows.
#
# Re-run safely — every step is idempotent.
#
# Env knobs:
#   CI=1                            run non-interactively (no WSL prompt)
#   APPLY_WSL_PERMISSIONS=false     skip the WSL block entirely
#   NO_COLOR=1                      disable ANSI colors

set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$PROJECT_ROOT"

# ---- prerequisites --------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo -e "${RED}Error: '$1' is required but not installed.${NC}" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd git
require_cmd python3

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker Compose V2 plugin is required but not installed.${NC}"
    echo ""
    echo "You appear to have the standalone 'docker-compose' (V1), which is deprecated."
    echo ""
    echo "Install the Docker Compose V2 plugin:"
    echo "  - Docker Desktop (Windows/Mac): Update to the latest version"
    echo "  - Linux/WSL: sudo apt-get update && sudo apt-get install docker-compose-plugin"
    echo "  - Or see: https://docs.docker.com/compose/install/"
    exit 1
fi

echo -e "${GREEN}Mustry Academy — Lab 04 setup${NC}"
echo "================================"
echo ""
echo "This script initializes the development environment:"
echo "  - three Ignition 8.3 gateways:"
echo "      local  http://localhost:8088   (your working gateway, bind-mounted from the repo)"
echo "      dev    http://localhost:8089   (populated by deploy.yml on push to main)"
echo "      prod   http://localhost:8090   (populated by release.yml on tag push)"
echo "  - one TimescaleDB on localhost:5432 hosting ignition_loc / ignition_dev / ignition_prd"
echo ""

# ---- WSL compatibility ---------------------------------------------------
apply_wsl_permissions() {
    if [ "${APPLY_WSL_PERMISSIONS:-true}" != "true" ]; then
        return 0
    fi

    if ! grep -qi microsoft /proc/version 2>/dev/null; then
        return 0
    fi

    echo -e "${YELLOW}WSL detected: configuring for WSL compatibility.${NC}"

    git config core.fileMode false

    if ! grep -q "metadata" /etc/wsl.conf 2>/dev/null; then
        echo ""
        echo -e "${YELLOW}Warning: Your /etc/wsl.conf does not have metadata mount options.${NC}"
        echo -e "${YELLOW}This can cause file permission issues in VS Code.${NC}"
        echo ""
        if [ "${CI:-}" = "1" ] || [ ! -t 0 ]; then
            echo "Skipping interactive prompt (CI or non-interactive shell)."
            echo "Add the following to /etc/wsl.conf manually if you hit perms issues:"
            echo "  [automount]"
            echo "  enabled = true"
            echo '  options = "metadata,umask=022,fmask=011"'
            return 0
        fi
        read -p "Would you like to configure it now? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            sudo tee /etc/wsl.conf > /dev/null <<'WSLCONF'
[automount]
enabled = true
options = "metadata,umask=022,fmask=011"
WSLCONF
            echo -e "${GREEN}wsl.conf updated. Run 'wsl --shutdown' from PowerShell and restart WSL for changes to take effect.${NC}"
        else
            echo "Skipping. You can manually add the following to /etc/wsl.conf:"
            echo ""
            echo "  [automount]"
            echo "  enabled = true"
            echo '  options = "metadata,umask=022,fmask=011"'
            echo ""
        fi
    fi
}

apply_wsl_permissions

# ---- Git hooks ------------------------------------------------------------
install_git_hooks() {
    local repo_hooks_dir
    repo_hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)" || return 0
    local source_dir="$PROJECT_ROOT/scripts/git-hooks"
    [ -d "$source_dir" ] || return 0
    mkdir -p "$repo_hooks_dir"
    for hook in post-merge post-checkout post-rewrite; do
        local target="$repo_hooks_dir/$hook"
        ln -sf "$source_dir/$hook" "$target"
    done
    if [ -x "$source_dir/skip-worktree-ignition-resources" ]; then
        "$source_dir/skip-worktree-ignition-resources" || true
    fi
}

install_git_hooks

# ---- Git diff driver --------------------------------------------------------
# .gitattributes routes resource.json through this textconv normalizer so
# volatile Designer metadata (timestamps, signatures) never shows up in diffs.
configure_git_diff_drivers() {
    git config diff.ignition-resource.textconv "$PROJECT_ROOT/scripts/git-diff/normalize-ignition-resource-json.py"
}

configure_git_diff_drivers

# ---- .env -----------------------------------------------------------------
ensure_env_file() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi
    if [ ! -f "$PROJECT_ROOT/.env.example" ]; then
        echo -e "${RED}Error: neither .env nor .env.example found.${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}.env not found — copying from .env.example.${NC}"
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "${YELLOW}Edit .env to set gateway passwords; the IGNITION_API_KEY_* values${NC}"
    echo -e "${YELLOW}are filled in after first login to each gateway.${NC}"
    echo ""
}

ensure_env_file

# ---- Runner registration token (no PAT — minted via gh, like Lab 03) ------
# The bundled github-runner registers with a short-lived registration token
# rather than a Personal Access Token. We mint that token here with the GitHub
# CLI, export it, and let `docker compose up` hand it to the runner container.
# gh is optional: without it the gateways still come up, only the runner stays
# unregistered until you install gh and re-run setup.
ensure_runner_token() {
    local repo_url owner_repo
    repo_url="$(env_value RUNNER_REPO_URL)"
    if [ -z "$repo_url" ] || printf '%s' "$repo_url" | grep -q '<your-github-user>'; then
        echo -e "${YELLOW}RUNNER_REPO_URL is not pointed at your fork in .env — skipping runner registration.${NC}"
        echo "  Set RUNNER_REPO_URL=https://github.com/<you>/cicd-lab-04-ignition-file-based-deploy in .env,"
        echo "  then re-run scripts/setup.sh to register the runner."
        return 0
    fi
    if ! command -v gh > /dev/null 2>&1; then
        echo -e "${YELLOW}GitHub CLI (gh) not installed — skipping runner registration.${NC}"
        echo "  Install gh (https://cli.github.com), run 'gh auth login', then re-run setup."
        return 0
    fi
    if ! gh auth status > /dev/null 2>&1; then
        echo -e "${YELLOW}gh is not authenticated — skipping runner registration.${NC}"
        echo "  Run 'gh auth login', then re-run scripts/setup.sh."
        return 0
    fi
    # https://github.com/<owner>/<repo>(.git) -> <owner>/<repo>
    owner_repo="${repo_url#https://github.com/}"
    owner_repo="${owner_repo#git@github.com:}"
    owner_repo="${owner_repo%.git}"
    owner_repo="${owner_repo%/}"
    echo -e "${GREEN}Minting a runner registration token via gh for ${owner_repo}...${NC}"
    if RUNNER_TOKEN="$(gh api -X POST "repos/${owner_repo}/actions/runners/registration-token" --jq .token 2> /dev/null)" \
        && [ -n "$RUNNER_TOKEN" ]; then
        export RUNNER_TOKEN
        echo -e "${GREEN}  runner token ready.${NC}"
    else
        echo -e "${YELLOW}  couldn't mint a token — is ${owner_repo} your fork, and do you have access?${NC}"
        echo "  The stack will still come up; fix access and re-run setup to register the runner."
    fi
}

ensure_runner_token

# ---- Dev/prod gateway state dirs + API-token pre-seed ----------------------
# dev and prod bind-mount ./gateways/<gw>/{projects,config} (see
# docker-compose.yaml) so you can verify a deploy landed straight from the
# host: `ls gateways/dev/projects`. Create the dirs before compose up and
# pre-seed the committed `cicd` API token into config/ BEFORE the gateway's
# first boot: the scan API only accepts tokens the gateway has LOADED, and
# the deploy workflow cannot scan its own token in (chicken-and-egg — the
# scan call already needs it). With the token on disk at first boot the
# gateway loads it while commissioning; the 403 that commissioning's
# permission reset causes is repaired further down.
seed_gateway_state() {
    local gw token_src manifest_src core_dst
    token_src="$PROJECT_ROOT/services/config/resources/core/ignition/api-token"
    # The collection manifest MUST accompany any pre-seeded resource: on first
    # boot the gateway creates the `core` collection and refuses a non-empty
    # dir that has no manifest ("Resource collection path ... exists but is
    # not empty" -> FAULTED).
    manifest_src="$PROJECT_ROOT/services/config/resources/core/config-mode.json"
    for gw in dev prod; do
        mkdir -p "$PROJECT_ROOT/gateways/$gw/projects" "$PROJECT_ROOT/gateways/$gw/config"
        core_dst="$PROJECT_ROOT/gateways/$gw/config/resources/core"
        if [ -d "$token_src" ] && [ -f "$manifest_src" ] \
           && [ ! -d "$core_dst/ignition/api-token" ]; then
            mkdir -p "$core_dst/ignition"
            cp "$manifest_src" "$core_dst/config-mode.json"
            cp -R "$token_src" "$core_dst/ignition/"
        fi
    done
}

seed_gateway_state

# ---- Start the stack ------------------------------------------------------
existing_id="$(docker compose ps -q ignition-local 2>/dev/null || true)"
if [ -n "$existing_id" ]; then
    echo -e "${YELLOW}Stack already running — 'docker compose up -d' will be a no-op or apply changes.${NC}"
fi
echo -e "${GREEN}Starting the stack...${NC}"
if [ -n "${RUNNER_TOKEN:-}" ]; then
    docker compose up -d
else
    # Without a registration token the runner container would just
    # restart-loop on "Invalid configuration provided for token", so don't
    # start it at all. Fix RUNNER_REPO_URL in .env (and gh auth), then
    # re-run scripts/setup.sh to mint a token and bring the runner up.
    echo -e "${YELLOW}No runner registration token — starting the stack WITHOUT the github-runner service.${NC}"
    docker compose up -d --scale github-runner=0
fi
echo ""
docker compose ps
echo ""

# ---- Wait for the gateways ------------------------------------------------
wait_for_gateway() {
    local gateway="$1"
    local url
    url="$(gateway_url "$gateway")"
    echo -e "${GREEN}Waiting for $gateway gateway at $url to become RUNNING...${NC}"
    local attempts=0
    local max_attempts=120  # ~4 minutes per gateway; cold start is slow
    while [ $attempts -lt $max_attempts ]; do
        local state
        state="$(curl -fsS "${url}/StatusPing" 2>/dev/null | grep -o RUNNING || true)"
        if [ "$state" = "RUNNING" ]; then
            echo ""
            echo -e "${GREEN}  $gateway gateway RUNNING${NC}"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 2
        echo -n "."
    done
    echo ""
    local container
    container="$(gateway_container "$gateway")"
    echo -e "${RED}Error: $gateway gateway did not reach RUNNING within $((max_attempts * 2))s.${NC}" >&2
    echo "  Check logs:  docker logs --tail 200 $container" >&2
    return 1
}

# Wait for each in series. Could be parallelized; sequential output is
# easier to scan and the total cold-start time is dominated by the JVM
# startup of each gateway anyway.
for gw in "${LAB_GATEWAYS[@]}"; do
    wait_for_gateway "$gw"
done

# ---- API-permission repair (first boot only) ------------------------------
# On the FIRST boot of a fresh gateway container, Ignition's auto-commissioning
# resets the read/write permissions in security-properties, which locks the
# pre-provisioned API key out: it still authenticates (bad key = 401) but every
# call gets 403. Detect that and graft the APIToken permissions back
# (scripts/fix-gateway-api-perms.sh restarts the affected gateways). A 401 with
# the correct key means the gateway never LOADED the token resource (e.g. the
# stack was first started with `docker compose up` directly, so the pre-seed
# above never ran before first boot): make sure the token is on disk, restart
# that gateway so it loads it, then fall through to the 403 repair. Later
# setups skip all of this: the data volumes persist, so commissioning runs
# only once.
probe_scan_api() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
        -H "X-Ignition-API-Token: $IGNITION_API_KEY" \
        "$(gateway_url "$1")/data/api/v1/scan/projects" || true
}

repair_api_perms() {
    load_api_key_from_env local
    if is_placeholder_api_key; then
        return 0   # no key to probe with; initial_scan prints the guidance
    fi
    local needs_fix=() needs_load=()
    local gw code
    for gw in "${LAB_GATEWAYS[@]}"; do
        code="$(probe_scan_api "$gw")"
        case "$code" in
            403) needs_fix+=("$gw") ;;
            401) needs_load+=("$gw") ;;
        esac
    done
    if [ ${#needs_load[@]} -gt 0 ]; then
        echo -e "${YELLOW}API token not loaded yet on: ${needs_load[*]} — seeding the token and restarting...${NC}"
        seed_gateway_state
        for gw in "${needs_load[@]}"; do
            docker restart "$(gateway_container "$gw")" >/dev/null
        done
        for gw in "${needs_load[@]}"; do
            wait_for_gateway "$gw"
            code="$(probe_scan_api "$gw")"
            [ "$code" = "403" ] && needs_fix+=("$gw")
        done
    fi
    [ ${#needs_fix[@]} -eq 0 ] && return 0
    echo -e "${YELLOW}First-boot commissioning reset the API permissions on: ${needs_fix[*]}${NC}"
    echo "Grafting the APIToken permissions back and restarting..."
    "$SCRIPT_DIR/fix-gateway-api-perms.sh" "${needs_fix[@]}"
}

repair_api_perms

# ---- Initial scan (local only) -------------------------------------------
# Local has projects on disk from the bind mount; dev/prod start empty by
# design (workflows will populate them).
initial_scan() {
    if [ ! -x "$SCRIPT_DIR/scan.sh" ]; then
        echo -e "${YELLOW}scripts/scan.sh missing or not executable, skipping initial scan.${NC}"
        return 0
    fi

    load_api_key_from_env local
    if is_placeholder_api_key; then
        echo -e "${YELLOW}No API key in .env yet — skipping initial scan.${NC}"
        echo "  The lab ships a pre-provisioned token; copy the IGNITION_API_KEY_* lines"
        echo "  from .env.example into .env, then run:"
        echo "    scripts/scan.sh both --gateway local"
        return 0
    fi

    echo -e "${GREEN}Triggering initial scan on local gateway...${NC}"
    if ! "$SCRIPT_DIR/scan.sh" both --gateway local; then
        echo ""
        echo -e "${YELLOW}Initial scan failed (likely the key lacks scan permission).${NC}"
        echo "  Fix the role for the API key, then run:  scripts/scan.sh both --gateway local"
    fi
}

initial_scan

# ---- Done -----------------------------------------------------------------
# Pull the actual values from .env so the output matches reality.
ACTUAL_LOCAL_USER="$(env_value GATEWAY_ADMIN_USERNAME_LOCAL)"
ACTUAL_LOCAL_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_LOCAL)"
ACTUAL_DEV_USER="$(env_value GATEWAY_ADMIN_USERNAME_DEV)"
ACTUAL_DEV_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_DEV)"
ACTUAL_PROD_USER="$(env_value GATEWAY_ADMIN_USERNAME_PROD)"
ACTUAL_PROD_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_PROD)"
ACTUAL_PG_USER="$(env_value POSTGRES_USER)"
ACTUAL_PG_PASS="$(env_value POSTGRES_PASSWORD)"

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
printf "Gateways:\n"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "local"  "http://localhost:8088"  "${ACTUAL_LOCAL_USER:-admin}"  "${ACTUAL_LOCAL_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "dev"    "http://localhost:8089"  "${ACTUAL_DEV_USER:-admin}"    "${ACTUAL_DEV_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "prod"   "http://localhost:8090"  "${ACTUAL_PROD_USER:-admin}"   "${ACTUAL_PROD_PASS:-(see .env)}"
echo ""
echo "TimescaleDB:"
echo "  Host: localhost  Port: 5432"
echo "  Databases: ignition_loc, ignition_dev, ignition_prd"
echo "  Username: ${ACTUAL_PG_USER:-ignition}  Password: ${ACTUAL_PG_PASS:-(see .env)}"
echo ""
if is_placeholder_api_key; then
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  The lab ships a pre-provisioned API token (services/config/.../api-token/cicd);"
    echo "  copy the IGNITION_API_KEY_* lines from .env.example into .env — the same key"
    echo "  works on all three gateways."
    echo "  The deploy/release workflows take their keys from GitHub secrets on"
    echo "  the lab-gateway-dev / lab-gateway-prod environments — set those too"
    echo "  when you're ready to run CI."
    echo ""
fi
echo "Useful commands:"
echo "  docker compose ps                          # check container state"
echo "  docker logs -f lab04-ignition-local        # tail local gateway logs"
echo "  scripts/scan.sh both               # rescan local (default)"
echo "  scripts/scan.sh both --gateway dev # rescan dev"
echo "  scripts/teardown.sh                        # stop the stack"
echo "  scripts/teardown.sh --volumes              # stop and wipe persistent data"
