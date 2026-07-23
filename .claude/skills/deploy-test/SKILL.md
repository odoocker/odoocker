---
name: deploy-test
description: |
  DevOps deployment and testing skill for the Grove multi-tenant ecosystem.
  Use when deploying to DigitalOcean, testing locally with OrbStack, spinning up
  sandbox/QA environments, running docker compose stacks, debugging containers,
  managing domains/TLS, or when the user mentions "deploy", "test environment",
  "staging", "sandbox", "orbstack", "local test", "production", "CI/CD",
  "docker compose up", "ghost", "nginx", or "droplet".
version: 1.1.0
user-invocable: false
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Agent
---

# Grove Deploy & Test Skill

## Overview

Unified DevOps skill for the Gather at the Grove ecosystem — covers local testing
with OrbStack, DigitalOcean droplet deployment, sandbox/QA environments, and CI/CD.

**Stack**: Odoo 19 + PostgreSQL 17 + Nginx + Ghost CMS (x3) + 4 Next.js frontends (hub + 3 storefronts) + KeyDB + MinIO
**Tenants**: Goldberry Grove Farm, George George George Woodworking LLC, At The Grove Nursery LLC
**Infrastructure**: DigitalOcean Droplet (Docker Compose) + OrbStack (local dev)

---

## Quick Decision Tree

```
What do you need?
├── Local development/testing
│   ├── Quick test → OrbStack: Local Compose (Method 1)
│   ├── Full stack with Ghost → OrbStack: Grove Overlay (Method 2)
│   └── Sandbox/QA testing → OrbStack: Sandbox Overlay (Method 3)
│
├── Deploy to production
│   ├── First deploy → Production Setup Checklist
│   ├── Code update → SSH + git pull + compose restart
│   └── Config change → Update .env + compose up -d
│
├── CI/CD
│   ├── PR validation → GitHub Actions (ci.yml — already configured)
│   └── Auto-deploy → GitHub Actions Deploy Workflow
│
└── Debug/troubleshoot
    ├── Container won't start → Docker Logs Analysis
    ├── Domain/TLS issues → Nginx + Let's Encrypt Debug
    └── Database issues → Postgres Troubleshooting
```

---

## Environment Matrix

| Environment | Compose Files | .env Source | Domain |
|-------------|--------------|-------------|--------|
| **Local** | `base` + `override.local.yml` | `.env` (from `.env.example`) | `localhost:8069` |
| **Grove Local** | `base` + `override.grove.yml` + `override.local.yml` | `.env` + `.env.grove` | `localhost:8069` + Ghost 2368-2370 + frontends 3000-3003 (and `*.localhost` via nginx-proxy with `--profile proxy --profile frontends`) |
| **Sandbox/QA** | `base` + `override.grove.yml` + `override.sandbox.yml` | `.env` + `.env.grove` (sandbox vars) | `erp-sandbox.goldberrygrove.farm` |
| **Production** | `base` + `override.grove.yml` + `override.production.yml` | `.env` + `.env.grove` | `erp.gatheringatthegrove.com` |

---

## Local Testing with OrbStack

### Why OrbStack

OrbStack replaces Docker Desktop on macOS with better performance, native
networking, and Kubernetes support. It's already the active Docker context
for this project.

| Feature | OrbStack | Docker Desktop |
|---------|----------|----------------|
| Memory usage | ~200 MB | ~2 GB |
| Startup time | < 2s | 30-60s |
| Linux VM access | `orb` shell | N/A |
| Docker context | `orbstack` (active) | `default` |
| Kubernetes | Built-in, optional | Built-in, heavier |
| File sharing | VirtioFS (fast) | gRPC-FUSE (slower) |

### Method 1: Basic Local Stack (Odoo + Postgres only)

```bash
# From project root
cp .env.example .env
# Edit .env — set APP_ENV=local, WORKERS=0, DEV_MODE=reload,xml

docker compose -f docker-compose.yml \
  -f docker-compose.override.local.yml \
  --profile odoo --profile postgres \
  up -d

# Access: http://localhost:8069
```

### Method 2: Full Grove Stack (Ghost CMS + frontends behind nginx)

```bash
cp .env.example .env
cp .env.grove.example .env.grove

# Edit .env.grove — for local testing, override Ghost URLs:
# GHOST_GOLDBERRY_URL=http://localhost:2368
# GHOST_GGG_URL=http://localhost:2369
# GHOST_NURSERY_URL=http://localhost:2370

# Pull the frontend images first (built + published by grove-sites CI):
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.local.yml \
  --profile frontends pull

docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.local.yml \
  --profile odoo --profile postgres --profile nginx \
  --profile proxy --profile frontends \
  up -d

# Backend / CMS (direct ports):
# Odoo: http://localhost:8069
# Ghost Goldberry/GGG/Nursery: http://localhost:2368 / :2369 / :2370

# Frontends — direct dev ports:
# Hub: http://localhost:3000   Goldberry: http://localhost:3001
# GGG: http://localhost:3002   Nursery:   http://localhost:3003

# Frontends — behind nginx-proxy on :80 (GOL-5 acceptance path).
# `*.localhost` resolves to 127.0.0.1 in modern browsers/curl:
for h in hub goldberry ggg nursery; do
  echo "$h.localhost → $(curl -s -o /dev/null -w '%{http_code}' http://$h.localhost)"
done
```

> The `proxy` + `frontends` profiles are what put the 4 Next.js apps *behind
> nginx*. Drop `--profile proxy` and you still get the direct dev ports, but the
> `*.localhost` vhosts won't answer. VIRTUAL_HOST defaults to `<name>.localhost`
> in `override.local.yml`; override per-host via `.env` for preview/prod domains.

### Method 3: Sandbox/QA Environment

```bash
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.sandbox.yml \
  --profile odoo --profile postgres --profile nginx \
  up -d

# Uses APP_ENV=staging, DB=grove_sandbox, Ghost in development mode
# All containers have restart: "no" — failures are visible immediately
```

### OrbStack-Specific Tips

```bash
# Access the Linux VM directly
orb

# View container resource usage (lighter than docker stats)
orbctl status

# Reset Docker state without restarting
docker system prune -f

# OrbStack automatically handles:
# - Port forwarding (no extra config needed)
# - DNS resolution for containers
# - File mount performance (VirtioFS)
# - Resource limits (respects compose deploy.resources)
```

### Validating Local Environment

```bash
# 1. Check all containers are running
docker compose ps

# 2. Check Odoo is responding
curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/web/login

# 3. Check Postgres connectivity
docker compose exec postgres pg_isready -U odoo

# 4. Check Ghost instances (if grove overlay active)
for port in 2368 2369 2370; do
  echo "Ghost :$port → $(curl -s -o /dev/null -w '%{http_code}' http://localhost:$port)"
done

# 5. Check nginx proxy chain (if nginx profiles active)
docker compose logs nginx --tail 20

# 6. Validate env var expansion
docker compose config --services
```

---

## DigitalOcean Production Deployment

### Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │         DigitalOcean Droplet                 │
                    │         (4 GB RAM / 2 vCPU min)             │
                    │                                             │
  HTTPS ──────────► │  nginx-proxy (:80/:443)  [profile: proxy]   │
                    │    │  routes by container VIRTUAL_HOST       │
                    │    ├── acme-companion (Let's Encrypt)        │
                    │    │                                         │
                    │    ├── nginx (inner) ──► Odoo (:8069)        │
                    │    │     erp.* catch-all → proxy_pass odoo   │
                    │    │                                         │
                    │    ├── Ghost routing (grove-ghost.conf)      │
                    │    │    ├── blog.goldberrygrove.farm         │
                    │    │    │     → ghost-goldberry (:2368)      │
                    │    │    ├── blog.woodworkingeorge.com        │
                    │    │    │     → ghost-ggg (:2369)            │
                    │    │    └── blog.atthegrovenursery.com       │
                    │    │          → ghost-nursery (:2370)        │
                    │    │                                         │
                    │    └── Frontends (Next.js) [profile:         │
                    │         frontends] — VIRTUAL_HOST per app    │
                    │         ├── gatheringatthegrove.com          │
                    │         │     → hub (:3000)                  │
                    │         ├── goldberrygrove.farm              │
                    │         │     → goldberry (:3001)            │
                    │         ├── woodworkingeorge.com             │
                    │         │     → ggg (:3001)                  │
                    │         └── atthegrovenursery.com            │
                    │               → nursery (:3001)              │
                    │                                             │
                    │  PostgreSQL 17                               │
                    │  KeyDB (Redis-compatible)                    │
                    │  MinIO (S3-compatible)                       │
                    └─────────────────────────────────────────────┘

  Frontend images: ghcr.io/goldberry-playground/grove-{hub,goldberry,ggg,nursery}
  (built + published by grove-sites CI). Each carries VIRTUAL_HOST / VIRTUAL_PORT
  / LETSENCRYPT_HOST, empty by default → nginx-proxy ignores them until a host is
  set (local: `<name>.localhost`; preview/prod: real domains via .env).
```

### Domains & DNS

| Domain | Purpose | Points To |
|--------|---------|-----------|
| `erp.gatheringatthegrove.com` | Odoo backend/admin | Droplet IP |
| `goldberrygrove.farm` | Goldberry Grove website | Droplet IP |
| `woodworkingeorge.com` | George George George Woodworking LLC website | Droplet IP |
| `atthegrovenursery.com` | At The Grove Nursery website | Droplet IP |
| `blog.goldberrygrove.farm` | Ghost CMS (Goldberry) | Droplet IP |
| `blog.woodworkingeorge.com` | Ghost CMS (GGG) | Droplet IP |
| `blog.atthegrovenursery.com` | Ghost CMS (Nursery) | Droplet IP |

All DNS A-records must point to the droplet's public IP. The nginx-proxy container
reads VIRTUAL_HOST and routes accordingly. acme-companion auto-obtains TLS certs
for every domain in LETSENCRYPT_HOST.

### First Deploy Checklist

```bash
# 1. Provision droplet (Ubuntu 24.04, Docker pre-installed)
# 2. SSH in and clone the repo
ssh root@<DROPLET_IP>
git clone <REPO_URL> /opt/grove && cd /opt/grove

# 3. Configure environment
cp .env.example .env
cp .env.grove.example .env.grove
# Edit both files with production values:
#   - Real domain names
#   - Strong passwords (ADMIN_PASSWD, DB_PASSWORD, etc.)
#   - WORKERS=4 (or 2*CPU+1)
#   - ACME_CA_URI → switch from staging to production Let's Encrypt
#   - APP_ENV=production

# 4. Switch Let's Encrypt to production
# In .env: ACME_CA_URI=https://acme-v02.api.letsencrypt.org/directory

# 5. Bring up the full stack (include --profile frontends once the per-app
#    *_VIRTUAL_HOST / *_LETSENCRYPT_HOST values are set in .env.grove; without
#    those the frontends start but nginx-proxy won't route a public vhost).
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  --profile odoo --profile postgres --profile nginx --profile proxy --profile acme \
  --profile frontends \
  up -d

# 6. Verify TLS certificates (may take 1-2 minutes)
curl -vI https://erp.gatheringatthegrove.com 2>&1 | grep -i "subject\|issuer"

# 7. Create Odoo database
# Visit https://erp.gatheringatthegrove.com/web/database/manager
```

### Updating Production

```bash
ssh root@<DROPLET_IP>
cd /opt/grove

# Pull latest code
git pull origin main

# Rebuild only if Dockerfile changed
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  build odoo

# Restart with zero-downtime for config changes
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  up -d --no-deps odoo nginx
```

---

## CI/CD with GitHub Actions

### Workflows on odoocker

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push/PR to `main` | Lint Python (Ruff), validate compose YAML, validate nginx config, third-party-addon branch check, reject tracked `.env`, gitleaks (push only), backend-stack smoke test |
| `docker-odoo.yml` | push/PR touching `odoo/**` or `.env.example` | Build `grove-odoo` image, smoke test (`odoo --stop-after-init`), Trivy scan (HIGH+CRITICAL blocking, `ignore-unfixed`), on main push to `ghcr.io/goldberry-playground/grove-odoo:{sha,latest}` |
| `release.yml` | semver tag push OR manual dispatch | Build + smoke + Trivy → require-approval (GitHub Environment gate) → deploy → post-deploy verify. Uses the `grove-odoo` image from `docker-odoo.yml`. |
| `sandbox-deploy.yml` | dispatch | Provision/refresh QA droplet via Terraform (`environments/sandbox/`), apply, smoke check. Posts `DISCORD_OPS_WEBHOOK_URL`. |
| `sandbox-reaper.yml` | cron daily | Detect QA droplets older than N hours and destroy them. Posts to Discord on action taken. |
| `terraform-drift.yml` | cron 6h | `terraform plan` against all envs, fail if non-zero diff. Posts to Discord. |
| Security scans (Trivy fs + image, gitleaks, pgadmin scan) | push/PR | Cleared as of 2026-06-17; HIGH+CRITICAL blocking. |

### Workflows on grove-sites

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push/PR to `main` | Lint, type-check, build all 4 frontends |
| `docker.yml` | push/PR touching `apps/**` | Matrix-build all 4 frontend images, smoke, Trivy, push to ghcr (main only) |
| `preview-up.yml` | PR labeled `qa` OR synchronize-while-labeled | Build the 4 frontend images for the PR SHA → `terraform apply` in `odoocker/infra/terraform/environments/preview/` to spin up a per-PR droplet with the PR's stack. Posts the URL to the PR + Discord. |
| `preview-down.yml` | PR closed/unlabeled | `terraform destroy` the per-PR droplet. |
| `release.yml` | semver tag push | Cuts a release of the frontend images. |

### Injection-safe pattern (enforced across all workflows)

All `${{ … }}` interpolations live in `env:` blocks; `run:` bodies use `$VAR` shell references. JSON payloads (Discord notifications) are built via `jq -n --arg`, which JSON-escapes every interpolated value — PR titles with backticks/quotes can't break out of the payload. Comment scripts read from `process.env.*`, not direct interpolation. **Never put literal `${{` text inside a `run: |` block** — even inside a bash `#` comment. GH parses run-blocks for expressions before bash sees them; empty/malformed `${{ }}` is a syntax error that rejects the entire workflow with `conclusion=failure` + empty `jobs[]` and no annotations. See `actionlint` for local validation.

### Required GitHub Secrets

**odoocker repo** (set; do NOT clear):

| Secret | Source | Used by |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | 1Password `GoldberryGrove Infra → do_token` | sandbox-deploy, sandbox-reaper, terraform-drift |
| `DISCORD_OPS_WEBHOOK_URL` | 1Password `GoldberryGrove Infra → discord_webhook_url` | sandbox-reaper, terraform-drift |
| `SPACES_ACCESS_KEY_ID` | TF-managed by `environments/state-backend/` | TF backend auth for all envs |
| `SPACES_SECRET_ACCESS_KEY` | TF-managed by `environments/state-backend/` | TF backend auth for all envs |

**grove-sites repo** (set via `environments/bootstrap/` TF apply, 10 secrets total):

| Secret | Source | Notes |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | TF-pushed | Same value as odoocker's, scoped via `do_token` var |
| `DISCORD_OPS_WEBHOOK_URL` | TF-pushed | Same Discord webhook |
| `DO_SPACES_ACCESS_KEY` | TF-managed (`grove-preview-data-rw` key) | For preview's own TF state ops + data uploads |
| `DO_SPACES_SECRET_KEY` | TF-managed | Pair of above |
| `ADMIN_IP_CIDR` | Operator input (`curl ifconfig.me`/32) | Preview droplet firewall allowlist |
| `PREVIEW_SSH_KEY_ID` | TF-managed (DO SSH key fingerprint) | Injected into preview droplet on create |
| `PREVIEW_SSH_PRIVATE_KEY` | Operator input (local `ssh-keygen` file) | For future operator SSH-in; not currently consumed by workflows |
| `GHOST_KEY_GOLDBERRY` | Operator input (Ghost Admin → Integrations) | Build-time |
| `GHOST_KEY_GGG` | Operator input (Ghost Admin → Integrations) | Build-time |
| `GHOST_KEY_NURSERY` | Operator input (Ghost Admin → Integrations) | Build-time |

For prod/sandbox SSH deploy (not yet wired): `PROD_HOST`, `PROD_SSH_KEY`, `PROD_SSH_USER`, `SANDBOX_HOST`, `SANDBOX_SSH_KEY`, `SANDBOX_SSH_USER` — placeholders in `release.yml`.

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs for the failing container
docker compose logs <service> --tail 50

# Common Odoo issues:
# - "database does not exist" → Create DB via /web/database/manager
# - "connection refused" on postgres → Postgres not ready yet, restart odoo
# - "Address already in use" → Another process on the port
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
```

### TLS/Certificate Issues

```bash
# Check acme-companion logs
docker compose logs letsencrypt --tail 30

# Common issues:
# - Still using staging CA → ACME_CA_URI must be production URL
# - DNS not propagated → nslookup <domain> should return droplet IP
# - Rate limited → Wait 1 hour, check https://letsencrypt.org/docs/rate-limits/

# Force cert renewal
docker compose exec letsencrypt /app/force_renew
```

### Postgres Issues

```bash
# Check postgres is running and accepting connections
docker compose exec postgres pg_isready -U odoo

# Check postgres logs for errors
docker compose logs postgres --tail 30

# Connect to postgres directly
docker compose exec postgres psql -U odoo -d postgres

# Check shared memory (if OOM or crashes)
docker compose exec postgres cat /proc/meminfo | grep Shmem
```

### Ghost CMS Issues

```bash
# Check individual Ghost instance
docker compose logs ghost-goldberry --tail 20

# Common issues:
# - "url" env var mismatch → Must match the public URL exactly
# - SQLite lock → Only one Ghost per volume, check mounts
# - Port conflict → Each Ghost must use a unique port (2368/2369/2370)
```

### OrbStack-Specific Issues

```bash
# Reset Docker state
orbctl stop && orbctl start

# Check OrbStack resource usage
orbctl status

# If containers are slow, check VirtioFS mounts
docker inspect <container> | jq '.[0].Mounts'

# Force rebuild from scratch (nuclear option)
docker compose down -v
docker system prune -af
docker compose up -d --build
```

---

## Best Practices

### Environment Isolation

1. **Never share `.env` files** between environments — each gets its own copy
2. **Use profiles** to control which services start: `--profile odoo --profile postgres`
3. **Sandbox uses `restart: "no"`** so failures surface immediately instead of restart-looping
4. **Production uses `restart: unless-stopped`** for auto-recovery

### Security

1. **Change default passwords** before first production deploy (ADMIN_PASSWD, DB_PASSWORD)
2. **Bind ports to 127.0.0.1** in production (done in `override.production.yml`)
3. **Switch ACME_CA_URI** from staging to production before go-live
4. **Set LIST_DB=False and DBFILTER** in production to prevent database enumeration
5. **Use SSH keys** for droplet access, disable password auth

### Performance

1. **PostgreSQL tuning** is in `.env.example` — calibrated for 4 GB RAM droplet
2. **Odoo workers** should be `2 * CPU_CORES + 1` in production (WORKERS=5 for 2 vCPU)
3. **Memory limits** in `override.production.yml` prevent OOM kills
4. **Ghost uses SQLite** — no additional database overhead per instance
5. **KeyDB** is Redis-compatible but more memory-efficient

### Compose File Layering

```bash
# Always layer files in this order:
# 1. Base:       docker-compose.yml           (service definitions)
# 2. Ecosystem:  docker-compose.override.grove.yml   (Ghost services)
# 3. Environment: docker-compose.override.<env>.yml  (ports, resources, restart)

# Local development
docker compose -f docker-compose.yml -f docker-compose.override.local.yml up

# Grove local
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.local.yml up

# Production
docker compose -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml up -d
```

---

## Integration with DigitalOcean Services

### Managed Database (Future Migration Path)

When traffic outgrows the self-hosted PostgreSQL:

1. Create DO Managed PostgreSQL: `doctl databases create grove-db --engine pg --version 17 --region nyc1 --size db-s-2vcpu-4gb`
2. Update `.env`: Set `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_SSLMODE=require` to managed DB values
3. Remove postgres from compose profiles
4. Add managed DB firewall: `doctl databases firewalls append <db-id> --rule ip_addr:<droplet-ip>`

### Spaces / S3

MinIO is the local S3-compatible store. DO Spaces is what's used in prod and for TF backend state.

**Provisioned buckets** (TF-managed, do NOT create by hand):

| Bucket | Managed by | Purpose |
|---|---|---|
| `grove-tf-state` | `environments/state-backend/` | Terraform state for ALL grove envs |
| `grove-preview-data` | `environments/bootstrap/` | Sanitized snapshots + filestore archives for previews (7-day lifecycle) |

**Two-keys pattern for DO Spaces TF management** — `digitalocean_spaces_bucket` talks S3 protocol (needs S3-style creds for the *provider*); `digitalocean_spaces_key` talks the DO REST API (uses `do_token`). To bootstrap a state bucket from scratch you need:
- **Plumbing key** (manually generated, All Buckets, Full Access) — used only by the DO provider for bucket-level ops. Long-lived; stored only in 1Password as `spaces_bootstrap_*`.
- **Workflow key** (TF-created, bucket-scoped, RW) — what CI actually consumes. Pushed to GH secrets by TF.

S3-backend config for non-AWS Spaces requires `skip_requesting_account_id = true` (newer TF/AWS provider tries STS GetCallerIdentity which rejects DO creds — added in PR #28).

For Odoo's app-level S3 (filestore), set `AWS_HOST=nyc3.digitaloceanspaces.com`, `AWS_REGION=us-east-1`, `AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY` from the bucket-scoped workflow key (not the plumbing key), and remove MinIO from the compose profile.

### Terraform environments

```
infra/terraform/environments/
├── state-backend/   # Provisions grove-tf-state bucket + RW key. Apply FIRST.
├── bootstrap/       # Preview prerequisites: grove-preview-data bucket, DNS
│                    # delegation, SSH key, 10 grove-sites GH secrets.
├── preview/         # Per-PR droplet (called by grove-sites preview-up.yml)
├── sandbox/         # QA droplet (called by odoocker sandbox-deploy.yml)
└── production/      # Prod droplet
```

Each env has `make {env}-{init,apply,destroy,plan,output}` targets; credentials injected via `op run --env-file=.env.op --` from `GoldberryGrove Infra` in 1Password. All envs use the same `backend.hcl.example` template + the same `skip_requesting_account_id` pattern.

### Secret-sync pattern (op → gh)

The canonical flow for any new secret:

1. Add a field to `GoldberryGrove Infra` in 1Password (`op item edit "GoldberryGrove Infra" --vault "Goldberry Grove - Admin" new_secret_name=...`).
2. Reference it in the env's `.env.op` (the `op run --env-file` source).
3. Wire it as a TF variable + `github_actions_secret` resource (or push directly via `op read | gh secret set <NAME> --repo <owner>/<repo>` for one-offs).
4. `make {env}-apply`.

No human-clicks-in-DO/GH-UI step. Length+prefix probe BEFORE syncing (caught a malformed DO token in PR #26 prep): `op read 'op://Goldberry Grove - Admin/GoldberryGrove Infra/do_token' | awk '{print length($0), substr($0,1,8)}'`.

Fine-grained GH PATs need both `Actions: Read & write` AND `Secrets: Read & write` — these are distinct permissions; missing `Secrets` returns 403 with `x-accepted-github-permissions` header showing the missing scope name.

### Load Balancer (Future Scaling)

For multi-droplet setup:
1. Create LB: `doctl compute load-balancer create --name grove-lb --region nyc1`
2. Point DNS to LB instead of droplet IP
3. Each droplet runs the same compose stack
4. Session affinity via Redis (already configured with KeyDB)
