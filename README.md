# Odoocker — Gather at the Grove

[![CI](https://github.com/Goldberry-Playground/odoocker-goldberrygrove/actions/workflows/ci.yml/badge.svg)](https://github.com/Goldberry-Playground/odoocker-goldberrygrove/actions/workflows/ci.yml)

Multi-tenant Docker Compose stack for the **Gather at the Grove** ecosystem — three businesses on a single Odoo 19 instance with Ghost CMS headless blogs.

| Business | Domain | Ghost Blog |
|----------|--------|------------|
| Goldberry Grove Farm | goldberrygrove.farm | blog.goldberrygrove.farm |
| George George George Woodworking, LLC | woodworkingeorge.com | blog.woodworkingeorge.com |
| At The Grove Nursery, LLC | atthegrovenursery.com | blog.atthegrovenursery.com |

> Fork of [odoocker](https://github.com/odoocker/odoocker) with Grove-specific overlays.

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Environment Variables](#environment-variables)
- [Services](#services)
- [Compose Override Files](#compose-override-files)
- [APP_ENV Modes](#app_env-modes)
- [Admin Panel Access](#admin-panel-access)
- [Multi-Tenant Architecture](#multi-tenant-architecture)
- [Custom Odoo Modules](#custom-odoo-modules)
- [SSL/TLS Setup](#ssltls-setup)
- [Backup and Restore](#backup-and-restore)
- [Development vs Production](#development-vs-production)
- [Deployment](#deployment)
- [Troubleshooting](#troubleshooting)
- [Related Repositories](#related-repositories)

## Architecture

```
                        ┌──────────────────┐
                        │   nginx-proxy     │
                        │   :80  :443       │
                        │   (Let's Encrypt) │
                        └────────┬─────────┘
                                 │
                ┌────────────────┼────────────────┐
                │                │                │
                ▼                ▼                ▼
┌───────────────────┐ ┌──────────────┐ ┌──────────────────┐
│      nginx         │ │  ghost-gold  │ │   ghost-ggg      │
│ (Odoo + Ghost      │ │  :2368       │ │   :2369          │
│  routing)          │ │  SQLite      │ │   SQLite         │
└────────┬──────────┘ └──────────────┘ └──────────────────┘
         │                                         │
         │            ┌──────────────┐             │
         │            │ ghost-nursery│             │
         │            │  :2370       │             │
         │            │  SQLite      │             │
         │            └──────────────┘             │
         ▼                                         │
┌─────────────────┐   ┌──────────────┐            │
│    Odoo 19       │   │  PostgreSQL   │           │
│    :8069         │──▶│  :5432        │           │
│  grove_headless  │   │  (shared DB)  │           │
│    API           │   └──────────────┘            │
└────────┬────────┘                                │
         │            ┌──────────────┐             │
         ├───────────▶│  KeyDB/Redis  │◀───────────┘
         │            │  (sessions)   │
         │            └──────────────┘
         │            ┌──────────────┐
         └───────────▶│  MinIO (S3)   │
                      │  (filestore)  │
                      └──────────────┘

┌──────────────────────┐
│  custom-modules-sync  │  ← git-sync from grove-odoo-modules repo
│  → /workspace/current │
└──────────────────────┘
```

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Docker | 24+ | [Install Docker](https://docs.docker.com/get-docker/) |
| Docker Compose | v2.20+ | Included with Docker Desktop / OrbStack |
| Git | 2.30+ | For cloning and git-sync |
| RAM | 4GB+ minimum | 8GB recommended for full stack with Ghost |
| Disk | 10GB+ free | For Docker images and volumes |

**Recommended Docker Runtime (macOS):** [OrbStack](https://orbstack.dev/) — faster and lighter than Docker Desktop.

## Quick Start

> **TL;DR for the full Grove ecosystem:** use the repo-root `Makefile`
> (`make stack-up`) — it wraps every flag below. The longhand commands here
> exist as documentation and for CI scripting.

### Local Development (Odoo + Postgres only)

```bash
# 1. Clone the repository
git clone git@github.com:Goldberry-Playground/odoocker-goldberrygrove.git
cd odoocker-goldberrygrove

# 2. Create environment files from examples
cp .env.example .env

# 3. Review and edit .env — at minimum set:
#    APP_ENV=local
#    DEV_MODE=reload,xml
#    DB_NAME=odoo
#    DOMAIN=localhost

# 4. Build and start
docker compose -f docker-compose.yml -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d --build

# 5. Check logs
docker compose logs -f odoo
```

Odoo will be available at **http://localhost:8069**.

### Local Development with Ghost CMS

```bash
# 1. Create Grove environment file (defines GHOST_*_URL variables)
cp .env.grove.example .env.grove

# 2. Start with BOTH env files loaded.
#    *** Forgetting --env-file .env.grove leaves Ghost containers with empty
#        url= env vars and they crash-loop with "URL in config must be
#        provided with protocol". ***
docker compose \
  -f docker-compose.yml \
  -f docker-compose.override.local.yml \
  -f docker-compose.override.grove.yml \
  --env-file .env --env-file .env.grove \
  --profile odoo --profile postgres --profile ghost up -d --build

# Ghost instances:
#   Goldberry: http://localhost:2368
#   GGG:       http://localhost:2369
#   Nursery:   http://localhost:2370
```

## Environment Variables

### `.env` — Core Configuration

The `.env` file controls all services. Create it from `.env.example`:

```bash
cp .env.example .env
```

**Key variables to configure:**

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_ENV` | `fresh` | Application mode — see [APP_ENV Modes](#app_env-modes) |
| `DOMAIN` | `erp.odoocker.test` | Primary Odoo domain |
| `DB_NAME` | `odoo` | PostgreSQL database name |
| `DB_USER` | `odoo` | Database user |
| `DB_PASSWORD` | `odoo` | Database password (**change in production**) |
| `ADMIN_PASSWD` | `odoo` | Odoo master/admin password (**change in production**) |
| `WORKERS` | `0` | Number of worker processes (0 = single-threaded, set 2+ for production) |
| `INIT` | — | Modules to install on startup (comma-separated) |
| `UPDATE` | — | Modules to update on startup (comma-separated) |
| `LOAD` | `base,web` | Modules to preload |
| `DEV_MODE` | — | Set to `reload,qweb` for hot reload in development |
| `LIST_DB` | `True` | Show database manager (set `False` in production) |
| `DBFILTER` | `.*` | Database name filter (restrict in production) |

**Services (enable/disable via profiles):**

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVICES` | `odoo,postgres` | Comma-separated list of Docker Compose profiles to activate |
| `USE_REDIS` | `false` | Enable KeyDB for session storage |
| `USE_S3` | `false` | Enable MinIO for S3-compatible filestore |
| `USE_PGADMIN` | `false` | Enable pgAdmin web interface |
| `USE_CUSTOM_MODULES_SYNC` | `false` | Enable git-sync for custom modules |

**Git-sync (custom modules):**

| Variable | Default | Description |
|----------|---------|-------------|
| `CUSTOM_MODULES_REPO` | — | GitHub repo URL for custom modules |
| `CUSTOM_MODULES_BRANCH` | `main` | Branch to sync |
| `CUSTOM_MODULES_SYNC_PERIOD` | `30s` | Polling interval |

**GitHub (for Enterprise edition):**

| Variable | Description |
|----------|-------------|
| `GITHUB_USER` | GitHub user with access to Odoo Enterprise repo |
| `GITHUB_ACCESS_TOKEN` | GitHub personal access token |

**CORS:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CORS_ALLOWED_DOMAIN` | `*` | Allowed CORS origins for API requests |
| `CLIENT_DOMAINS` | — | Comma-separated list of frontend domains |

### `.env.grove` — Grove-Specific Configuration

Create from `.env.grove.example`:

```bash
cp .env.grove.example .env.grove
```

| Variable | Description |
|----------|-------------|
| `GHOST_GOLDBERRY_URL` | Public URL for Goldberry Ghost blog |
| `GHOST_GGG_URL` | Public URL for GGG Ghost blog |
| `GHOST_NURSERY_URL` | Public URL for Nursery Ghost blog |
| `GHOST_GOLDBERRY_PORT` | Internal port (default: 2368) |
| `GHOST_GGG_PORT` | Internal port (default: 2369) |
| `GHOST_NURSERY_PORT` | Internal port (default: 2370) |
| `ODOO_DB_NAME` | Production database name |
| `ODOO_COMPANY_*_ID` | Odoo company IDs per tenant |
| `ODOO_WEBSITE_*_ID` | Odoo website IDs per tenant |
| `GROVE_HEADLESS_API_ENABLED` | Enable/disable REST API |
| `GROVE_GHOST_ENABLED` | Enable/disable Ghost services |

## Services

| Service | Image | Role | Ports |
|---------|-------|------|-------|
| **odoo** | Custom (Odoo 19) | ERP application server | 8069 (HTTP), 8071 (longpolling), 8072 (debug) |
| **postgres** | Custom (PostgreSQL 17) | Database | 5432 |
| **nginx** | nginx | Odoo reverse proxy + Ghost routing | 80 (internal) |
| **nginx-proxy** | nginxproxy/nginx-proxy | TLS termination, virtual host routing | 80, 443 |
| **letsencrypt** | nginxproxy/acme-companion | Automatic SSL certificate renewal | — |
| **redis** | eqalpha/keydb | Session storage | 6379 |
| **s3** | minio/minio | S3-compatible object storage (filestore) | 9000, 9001 |
| **pgadmin** | pgadmin | Database management UI | 80 (internal) |
| **custom-modules-sync** | git-sync | Syncs grove-odoo-modules repo | — |
| **ghost-goldberry** | ghost:5-alpine | Goldberry Grove blog CMS | 2368 |
| **ghost-ggg** | ghost:5-alpine | GGG Woodworking blog CMS | 2369 |
| **ghost-nursery** | ghost:5-alpine | At The Grove Nursery blog CMS | 2370 |

## Compose Override Files

Combine these files to configure different environments:

| File | Purpose | Use With |
|------|---------|----------|
| `docker-compose.yml` | Base services (Odoo, Postgres, nginx, etc.) | Always |
| `docker-compose.override.local.yml` | Local dev: ports exposed, no restart, modules bind-mounted | Development |
| `docker-compose.override.grove.yml` | Adds 3 Ghost CMS instances | Any Grove environment |
| `docker-compose.override.sandbox.yml` | Sandbox: staging DB, dev Ghost instances | QA/Testing |
| `docker-compose.override.production.yml` | Production: memory limits, restart policies, localhost binding | Production |

**Common combinations:**

```bash
# Local Odoo only
docker compose -f docker-compose.yml \
  -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d

# Local with Ghost
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.local.yml \
  --profile odoo --profile postgres up -d

# Production
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml up -d

# Sandbox/QA
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.sandbox.yml up -d
```

## APP_ENV Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `fresh` | No database created, empty init/update | First-time setup or database restore |
| `restore` | Same as fresh | Restoring a production backup |
| `local` | Follows `.env` variables, no overwrites | Regular development |
| `debug` | Like local + `debugpy` for VS Code debugging | Debugging with breakpoints |
| `testing` | Creates test DB, installs `ADDONS_TO_TEST`, runs `TEST_TAGS` | Running module tests |
| `full` | Installs `INIT` modules in `DB_NAME` | Fresh production DB replica |
| `staging` | Sets `UPDATE=all`, upgrades all installed addons | Pre-deployment validation |
| `production` | No demo data, no debug, enables Let's Encrypt | Live deployment |

## Admin Panel Access

| Panel | Local URL | Credentials |
|-------|-----------|-------------|
| **Odoo** | http://localhost:8069 | Admin user created on first run |
| **Odoo DB Manager** | http://localhost:8069/web/database/manager | `ADMIN_PASSWD` from `.env` |
| **Ghost Goldberry** | http://localhost:2368/ghost | Created on first visit |
| **Ghost GGG** | http://localhost:2369/ghost | Created on first visit |
| **Ghost Nursery** | http://localhost:2370/ghost | Created on first visit |
| **pgAdmin** | http://localhost:5050 (when enabled) | `PGADMIN_EMAIL` / `PGADMIN_PASSWORD` from `.env` |
| **MinIO Console** | http://localhost:9001 (when enabled) | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from `.env` |

## Multi-Tenant Architecture

This stack runs a single Odoo 19 instance with **3 companies** in **1 database**:

```
┌─────────────────────────────────────────────────┐
│              Odoo 19 (single instance)           │
│                                                  │
│  ┌──────────────┐ ┌──────────┐ ┌─────────────┐  │
│  │ Company 1     │ │Company 2  │ │ Company 3   │  │
│  │ Goldberry     │ │ GGG       │ │ Nursery     │  │
│  │ Grove Farm    │ │ Woodwork  │ │             │  │
│  └──────┬───────┘ └────┬─────┘ └──────┬──────┘  │
│         │              │              │          │
│  ┌──────┴───────┐ ┌────┴─────┐ ┌──────┴──────┐  │
│  │ Website 1     │ │Website 2  │ │ Website 3   │  │
│  │ goldberry     │ │ ggg       │ │ nursery     │  │
│  │ grove.farm    │ │ george.com│ │ nursery.com │  │
│  └──────────────┘ └──────────┘ └─────────────┘  │
└──────────────────────┬──────────────────────────┘
                       │
            grove_headless module
            /grove/api/v1/*
            X-Grove-Tenant header → company scoping
```

Each company has its own:
- **Website** record in Odoo (for tenant resolution)
- **Ghost CMS** instance (for blog content)
- **Product catalog** scoped by `company_id`

The React frontends send an `X-Grove-Tenant` header (`goldberry`, `ggg`, or `nursery`), and the `grove_headless` module resolves it to the correct company, scoping all data automatically.

## Custom Odoo Modules

Custom modules live in the [grove-odoo-modules](https://github.com/Goldberry-Playground/grove-odoo-modules) repository, NOT in `odoo/custom-addons/`.

### Local Development

The `docker-compose.override.local.yml` bind-mounts the modules repo:

```yaml
# ../grove-odoo-modules → /workspace/current inside the container
```

Clone the modules repo alongside this one:

```bash
cd ~/Documents/Dev\ Projects/gather-at-the-grove/
git clone git@github.com:Goldberry-Playground/grove-odoo-modules.git
```

After code changes, restart Odoo:

```bash
docker compose -f docker-compose.yml -f docker-compose.override.local.yml restart odoo
```

### Production

The `custom-modules-sync` container (git-sync) automatically pulls the latest `main` branch every 30 seconds. No Docker rebuild needed.

```bash
# Install/upgrade modules via CLI
docker compose exec odoo odoo -d odoo --init grove_headless --stop-after-init
docker compose exec odoo odoo -d odoo --update grove_headless --stop-after-init
```

## SSL/TLS Setup

SSL is handled automatically by the `letsencrypt` (ACME companion) container in production.

### Setup Steps

1. **Point DNS records** for all domains to your server:
   - `erp.goldberrygrove.farm`
   - `blog.goldberrygrove.farm`
   - `blog.woodworkingeorge.com`
   - `blog.atthegrovenursery.com`

2. **Switch from staging to production ACME** in `.env`:

   ```bash
   # Staging (for testing — issues untrusted certs):
   ACME_CA_URI=https://acme-staging-v02.api.letsencrypt.org/directory

   # Production (for go-live — issues trusted certs):
   ACME_CA_URI=https://acme-v02.api.letsencrypt.org/directory
   ```

3. **Set the Let's Encrypt email** in `.env`:

   ```bash
   DEFAULT_EMAIL=admin@goldberrygrove.farm
   ```

4. **Use the production compose override:**

   ```bash
   docker compose -f docker-compose.yml \
     -f docker-compose.override.grove.yml \
     -f docker-compose.override.production.yml up -d
   ```

Certificates are auto-renewed before expiration.

## Backup and Restore

### Odoo Database Backup

**Via Odoo UI:**

1. Go to `http://your-domain/web/database/manager`
2. Enter the master password (`ADMIN_PASSWD`)
3. Click **Backup** next to your database
4. Choose format (zip includes filestore)

**Via CLI:**

```bash
# Dump database
docker compose exec postgres pg_dump -U odoo -Fc odoo > backup_$(date +%Y%m%d).dump

# Backup filestore
docker compose cp odoo:/var/lib/odoo/filestore ./filestore_backup_$(date +%Y%m%d)
```

### Odoo Database Restore

**Via Odoo UI:**

1. Go to `http://your-domain/web/database/manager`
2. Click **Restore a database**
3. Upload your backup zip

**Via CLI:**

```bash
# Restore database
docker compose exec -T postgres pg_restore -U odoo -d odoo --clean < backup_20260401.dump

# Restore filestore
docker compose cp ./filestore_backup_20260401/. odoo:/var/lib/odoo/filestore/
```

### Ghost Backup

Ghost uses SQLite stored in Docker volumes:

```bash
# Copy Ghost data from each instance
docker compose cp ghost-goldberry:/var/lib/ghost/content ./ghost-goldberry-backup
docker compose cp ghost-ggg:/var/lib/ghost/content ./ghost-ggg-backup
docker compose cp ghost-nursery:/var/lib/ghost/content ./ghost-nursery-backup
```

## Development vs Production

| Aspect | Development | Production |
|--------|-------------|------------|
| `APP_ENV` | `local` or `debug` | `production` |
| `WORKERS` | `0` (single-threaded) | `2+` (multi-process) |
| `LIST_DB` | `True` | `False` |
| `ADMIN_PASSWD` | `odoo` | Strong password |
| `DEV_MODE` | `reload,qweb` | (empty) |
| Ports | Exposed to host | Bound to `127.0.0.1` |
| Restart policy | `no` | `unless-stopped` |
| Memory limits | None | 2GB Odoo, 2GB Postgres |
| SSL | None | Auto via Let's Encrypt |
| Custom modules | Bind-mounted from local | git-sync from GitHub |
| Demo data | Loaded | Disabled |

## Deployment

### Initial Deployment

```bash
# 1. Clone to server
git clone git@github.com:Goldberry-Playground/odoocker-goldberrygrove.git
cd odoocker-goldberrygrove

# 2. Configure environment
cp .env.example .env
cp .env.grove.example .env.grove
# Edit both files with production values:
#   - Strong passwords (ADMIN_PASSWD, DB_PASSWORD)
#   - Real domains
#   - Production ACME_CA_URI
#   - WORKERS=2 or more
#   - LIST_DB=False

# 3. Build and start
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  up -d --build

# 4. Check logs
docker compose logs -f odoo
```

### Subsequent Updates

```bash
# Pull latest changes
git pull origin main

# Rebuild and restart
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  up -d --build

# Check logs
docker compose logs -f odoo
```

### Full Upgrade (staging → production)

```bash
# 1. Backup database first!
docker compose exec postgres pg_dump -U odoo -Fc odoo > backup_$(date +%Y%m%d).dump

# 2. Pull everything fresh
docker compose down
git pull
docker compose pull
docker compose build --no-cache

# 3. Set APP_ENV=staging in .env temporarily to update all modules
# 4. Start and monitor
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  up -d
docker compose logs -f odoo

# 5. After upgrade completes, set APP_ENV=production in .env
# 6. Restart
docker compose restart odoo
```

## Troubleshooting

### View container logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f odoo
docker compose logs -f postgres
docker compose logs -f ghost-goldberry

# Last 200 lines
docker compose logs --tail 200 odoo
```

### Odoo won't start

```bash
# Check container status
docker compose ps

# Check Odoo logs for errors
docker compose logs odoo | tail -50

# Common fix: restart
docker compose restart odoo
```

### Database connection errors

```bash
# Verify Postgres is running
docker compose ps postgres

# Test connection from Odoo container
docker compose exec odoo python3 -c "import psycopg2; psycopg2.connect('host=postgres dbname=odoo user=odoo password=odoo')"
```

### Ghost returns 502

Ghost containers may take 30-60 seconds to start. Check:

```bash
docker compose logs ghost-goldberry | tail -20

# Restart if needed
docker compose restart ghost-goldberry
```

Also verify that `nginx/grove-ghost.conf` is mounted into the nginx container.

### TLS certificate issues

```bash
# Check ACME companion logs
docker compose logs letsencrypt

# Verify DNS resolves to your server
dig +short erp.goldberrygrove.farm

# If using staging certs, switch to production ACME_CA_URI in .env
```

### Disk space

```bash
# Check Docker disk usage
docker system df

# Clean unused images and volumes
docker system prune -a --volumes
```

### Odoo Shell (for debugging)

```bash
docker compose exec odoo bash
odoo shell --http-port=8071
```

### Never run `docker compose down -v` in production

The `-v` flag deletes all volumes, destroying:
- Database data
- Odoo filestore
- Ghost content
- Let's Encrypt certificates

Always backup before any destructive operation.

## Related Repositories

| Repo | Purpose |
|------|---------|
| [grove-sites](https://github.com/Goldberry-Playground/grove-sites) | Next.js monorepo — React frontends consuming Odoo and Ghost APIs |
| [grove-odoo-modules](https://github.com/Goldberry-Playground/grove-odoo-modules) | Custom Odoo 19 modules — `grove_headless` REST API |
| [odoocker](https://github.com/odoocker/odoocker) | Upstream framework this repo is forked from |

## License

Based on the [Official Odoo Docker](https://hub.docker.com/_/odoo/) setup. See upstream [odoocker](https://github.com/odoocker/odoocker) for license details.
