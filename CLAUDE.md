# Grove Ecosystem — Odoocker

Multi-tenant Docker Compose stack for **Gather at the Grove** ecosystem:
- **Goldberry Grove Farm** (`goldberrygrove.farm`)
- **George George George Woodworking, LLC** (`woodworkingeorge.com`)
- **At The Grove Nursery, LLC** (`atthegrovenursery.com`)

## Stack

Odoo 19 + PostgreSQL 17 + Nginx (reverse proxy + Let's Encrypt) + Ghost CMS (x3) + KeyDB + MinIO

## Architecture

4 custom Next.js sites (hub + 3 tenant storefronts) consume:
- **Odoo** via `grove_headless` REST API (e-commerce, inventory, CRM)
- **Ghost CMS** via Content API (headless blog at `/blog`)

Ghost is NOT the website — it's a headless content source. Next.js is the frontend.

## Related Repos

| Repo | Purpose |
|------|---------|
| `Goldberry-Playground/grove-odoo-modules` | Custom Odoo modules (deployed via git-sync) |
| `Goldberry-Playground/grove-sites` | Next.js 15 monorepo (hub + 3 tenant storefronts) — built + published to ghcr.io by grove-sites CI, pulled here under the `frontends` profile |

## Environment Architecture

| Environment | Compose Override | Key Differences |
|-------------|-----------------|-----------------|
| Local | `override.local.yml` | Ports exposed, `restart: no`, modules bind-mounted from `../grove-odoo-modules` |
| Grove Local | `override.grove.yml` + `override.local.yml` | Adds Ghost CMS instances + frontends (`--profile frontends`) |
| Sandbox/QA | `override.grove.yml` + `override.sandbox.yml` | `APP_ENV=staging`, sandbox DB |
| Production | `override.grove.yml` + `override.production.yml` | Memory limits, `restart: unless-stopped`, git-sync active |

## Local Development

Uses **OrbStack** as Docker runtime. Verify: `docker context ls` should show `orbstack *`.

```bash
# Start local stack (Odoo + Postgres only)
docker compose -f docker-compose.yml -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d

# Odoo: http://localhost:8069
```

## Custom Modules

Production modules live in `grove-odoo-modules` repo, NOT in `odoo/custom-addons/`.
Locally, `docker-compose.override.local.yml` bind-mounts `../grove-odoo-modules` to `/workspace/current`.

## MCP Server

Odoo MCP server (`odoo-mcp-multi`) is configured in `.mcp.json` for AI-assisted development.
Update the dev profile password: `odoo-mcp edit-profile --name dev --password <your-password>`

## Key Files

- `.env.example` — Full Odoo/Postgres/Nginx config template
- `.env.grove.example` — Grove-specific vars (Ghost URLs, company IDs)
- `nginx/grove-ghost.conf` — Ghost CMS routing by domain
- `docs/ARCHITECTURE.md` — System architecture and data flow diagrams
- `docs/DEPLOYMENT.md` — Production deployment checklist
- `docs/DEVELOPMENT.md` — Local development guide
- `docs/ADR/` — Architecture Decision Records
