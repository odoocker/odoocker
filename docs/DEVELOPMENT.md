# Local Development Guide

> Part of the Grove deployment story. See [`docs/DEPLOY-OVERVIEW.md`](./DEPLOY-OVERVIEW.md) for how local / QA / prod fit together.

## Quickstart (most common path)

```bash
cd ~/Documents/Dev\ Projects/gather-at-the-grove/odoocker
cp .env.example .env             # one-time
make all-up                      # full stack (postgres + odoo + frontends)
make monitoring-up               # optional: OpenObserve + Keep observability
make help                        # see all make targets
```

Then visit:
- Odoo: http://localhost:8069 (admin password from `.env`)
- Hub: http://localhost:3000
- Tenant frontends: http://localhost:3001-3003
- OpenObserve UI: http://localhost:5080 (if `monitoring-up`)

The sections below cover full first-time setup + the daily development loop.

## Prerequisites

- **OrbStack** (Docker runtime): `brew install orbstack`
- **Git**: access to `Goldberry-Playground` org
- **Claude Code** (optional): for AI-assisted development with Odoo MCP

## Initial Setup

```bash
# 1. Clone both repos side by side
cd ~/Documents/Dev\ Projects/gather-at-the-grove/
git clone git@github.com:Goldberry-Playground/odoocker-goldberrygrove.git odoocker
git clone git@github.com:Goldberry-Playground/grove-odoo-modules.git

# 2. Configure environment
cd odoocker
cp .env.example .env
# Edit .env: set APP_ENV=fresh for first run (creates DB via web UI)

# 3. Build and start
docker compose -f docker-compose.yml -f docker-compose.override.local.yml \
  --profile odoo --profile postgres build
docker compose -f docker-compose.yml -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d

# 4. Create database
# Visit http://localhost:8069/web/database/manager
# Master password is the ADMIN_PASSWD value from .env (default: odoo)

# 5. Switch to local mode for ongoing development
# Edit .env: APP_ENV=local, DEV_MODE=reload,xml
# Rebuild: docker compose ... build odoo && docker compose ... up -d
```

## Daily Workflow

```bash
# Start the stack
docker compose -f docker-compose.yml -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d

# View logs
docker compose -f docker-compose.yml -f docker-compose.override.local.yml logs -f odoo

# Stop
docker compose -f docker-compose.yml -f docker-compose.override.local.yml down
```

## Module Development

Custom modules live in `../grove-odoo-modules/`, which is bind-mounted into the Odoo container at `/workspace/current`.

1. Edit module files in `grove-odoo-modules/`
2. Changes to Python files require an Odoo restart (or use `DEV_MODE=reload`)
3. Changes to XML views require module upgrade:
   ```bash
   docker compose ... exec odoo odoo -u grove_headless --stop-after-init
   ```
4. To install a new module: Odoo > Apps > Update Apps List > search and install

## MCP Server (AI-Assisted Development)

```bash
# Install (one-time)
pipx install odoo-mcp-multi

# Configure profile
odoo-mcp edit-profile --name dev --password <your-admin-password>

# Test connection
odoo-mcp test --profile dev

# QA profile — points at the Level 3 QA instance with a dedicated Odoo
# API key (named `odoo-mcp-qa` under Josh's user; backup copy in the
# 1Password "Gatheringatthegrove" item). Lets AI sessions read/write QA
# Odoo data (products, orders, taxes, stock) as MCP tool calls -- no
# SSH, no ad-hoc XML-RPC scripts, no rebuilds.
odoo-mcp add-profile --name qa \
  --url https://odoo.qa.gatheringatthegrove.com \
  --database odoo --user <your-odoo-login> --password <api-key> --test

# Use in Claude Code — .mcp.json auto-configures the server (file is
# git-ignored; copy .mcp.json.example)
```

Change-delivery cheat sheet (what needs a rebuild vs not):

| Change | Path | Rebuild? |
|---|---|---|
| Odoo DATA (products, stock, taxes, orders) | MCP tools / XML-RPC | no |
| Custom module CODE (grove_headless etc.) | push to grove-odoo-modules main -> git-sync (~60s) + `-i`/`-u` module | no |
| Odoo core/image deps (pip, third-party addons) | grove-odoo image rebuild | yes |
| Frontends | grove-sites CI -> GHCR -> App Platform deploy_on_push | automatic |

## Full Grove Stack (with Ghost CMS)

```bash
cp .env.grove.example .env.grove

docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.local.yml \
  --profile odoo --profile postgres --profile nginx up -d

# Ghost instances:
# Goldberry: http://localhost:2368
# GGG:       http://localhost:2369
# Nursery:   http://localhost:2370
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Odoo won't start | Check `docker compose logs odoo --tail 30` |
| "database does not exist" | Create via `/web/database/manager` |
| Module not found | Restart Odoo, check addons_path in logs |
| Port conflict | `lsof -i :8069` to find conflicting process |
