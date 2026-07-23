# Grove Deploy Guide

> ⚠️ **HISTORICAL REFERENCE — DO NOT EXECUTE FOR PRODUCTION.** This doc describes the **pre-Level-3** production deploy procedure (nginx + manual ACME via Cloudflare + per-host A records). Production deployment is currently deferred pending Phase 6 of [`docs/ADR/007-level-3-app-platform-migration.md`](./ADR/007-level-3-app-platform-migration.md), which will rewrite production to use DO App Platform + Managed Postgres + tiny Odoo droplet — a fundamentally different shape from what this doc describes.
>
> **Use this doc for:**
> - Historical context on the pre-Level-3 deploy procedure
> - The QA / sandbox sections (still valid for those envs)
> - DNS / Cloudflare conventions (still apply)
>
> **Do NOT use this doc for:**
> - Provisioning production today — it would create technical debt that Phase 6 will throw away
>
> For the canonical "what should I do" entry point, see [`docs/DEPLOY-OVERVIEW.md`](./DEPLOY-OVERVIEW.md).

> This document supersedes `docs/DEPLOYMENT.md` (now deprecated — see note at top of that file).

## ⚠️ Before You Apply

1. **admin_cidr — SSH access control**: The example `terraform.tfvars` files contain `admin_cidr = "0.0.0.0/0"` (open to the entire internet). Before running `terraform apply` for **production**, replace this with your real office/VPN CIDR (e.g., `"203.0.113.42/32"`). Sandbox Droplets can use `0.0.0.0/0` since they self-destruct in 24 hours, but prod requires a restricted CIDR.

2. **DNS is in Cloudflare** (not DigitalOcean): After Terraform creates the Droplets, you must manually create A records in Cloudflare pointing to the Droplet IPs. See the "DNS" section below.

## Table of Contents

1. [DNS](#dns)
2. [One-time Setup](#one-time-setup)
3. [Sandbox Deploy](#sandbox-deploy)
4. [Smoke Test](#smoke-test)
5. [Teardown](#teardown)
6. [Rollback](#rollback)
7. [Production Deploy](#production-deploy)
8. [Follow-ups](#follow-ups)
9. [Cost Estimate](#cost-estimate)

---

## DNS

DNS records are **not** managed by Terraform — they live in **Cloudflare**.

After `terraform apply` completes for production, retrieve the Droplet IPs from outputs:

```bash
terraform -chdir=infra/terraform/environments/production output
# Outputs:
#   production_droplet_ip = "203.0.113.10"
#   monitoring_droplet_ip = "203.0.113.11"
```

Then log into Cloudflare and create the following **A records** (use the IPs above):

**Main app Droplet** (`203.0.113.10`):

- `gatheringatthegrove.com` → `203.0.113.10`
- `www.gatheringatthegrove.com` → `203.0.113.10`
- `goldberrygrove.farm` → `203.0.113.10`
- `www.goldberrygrove.farm` → `203.0.113.10`
- `woodworkingeorge.com` → `203.0.113.10`
- `www.woodworkingeorge.com` → `203.0.113.10`
- `atthegrovenursery.com` → `203.0.113.10`
- `www.atthegrovenursery.com` → `203.0.113.10`
- `erp.gatheringatthegrove.com` → `203.0.113.10`
- `blog.goldberrygrove.farm` → `203.0.113.10`
- `blog.woodworkingeorge.com` → `203.0.113.10`
- `blog.atthegrovenursery.com` → `203.0.113.10`

**Monitoring Droplet** (`203.0.113.11`):

- `grafana.gatheringatthegrove.com` → `203.0.113.11`
- `status.gatheringatthegrove.com` → `203.0.113.11`

---

## One-time Setup

### DigitalOcean Spaces bucket (Terraform remote state)

```bash
# Install doctl if needed: https://docs.digitalocean.com/reference/doctl/how-to/install/
doctl auth init

# Create the state bucket (once per account)
doctl spaces create grove-tf-state --region nyc3
```

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `DIGITALOCEAN_TOKEN` | DO API token (read+write) |
| `SPACES_ACCESS_KEY_ID` | DO Spaces access key (for Terraform state) |
| `SPACES_SECRET_ACCESS_KEY` | DO Spaces secret key |
| `DO_SSH_KEY_ID` | SSH key fingerprint or numeric ID in your DO account |
| `SANDBOX_SSH_PRIVATE_KEY` | Private key matching the `DO_SSH_KEY_ID` public key |
| `ENV_SANDBOX` | Full contents of `.env.sandbox` (multi-line secret) |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook for reaper + drift alerts |

### Local prerequisites

```bash
# Terraform >= 1.6
terraform -version

# doctl (for manual operations)
doctl version
```

---

## Sandbox Deploy

### Via GitHub Actions (recommended)

Apply the `qa` label to any PR. The `sandbox-deploy` workflow will:

1. Run `terraform apply` to create a `s-4vcpu-8gb` Droplet in `nyc3` with a 50 GB attached volume.
2. Poll for cloud-init completion (Docker installed, repo cloned at exact SHA).
3. SCP `.env.sandbox` from the `ENV_SANDBOX` secret.
4. Start the stack with `docker compose`.
5. Post a PR comment with the Droplet IP and service URLs.

The Droplet is tagged `auto-destroy` and will be reaped by the reaper workflow within 24 hours.

### Manually from your machine

```bash
# 1. Copy and fill in backend config
cp infra/terraform/environments/sandbox/backend.hcl.example \
   infra/terraform/environments/sandbox/backend.hcl
# Edit backend.hcl — add your Spaces credentials via env vars:
export AWS_ACCESS_KEY_ID=<your-spaces-key>
export AWS_SECRET_ACCESS_KEY=<your-spaces-secret>
export DIGITALOCEAN_TOKEN=<your-do-token>

# 2. Copy and fill in tfvars
cp infra/terraform/environments/sandbox/terraform.tfvars.example \
   infra/terraform/environments/sandbox/terraform.tfvars
# Edit terraform.tfvars — set git_sha, ssh_key_ids

# 3. Init + apply
make tf-init env=sandbox
make tf-apply env=sandbox

# 4. Get the IP
make tf-output env=sandbox
```

---

## Smoke Test

```bash
# SSH into the sandbox
ssh root@<DROPLET_IP>

# Check stack health
docker compose -p grove-sandbox ps

# Odoo responding?
curl -sf http://localhost:8069/web/login && echo "Odoo OK"

# Ghost blogs responding?
curl -sf http://localhost:2368 && echo "Ghost Goldberry OK"
curl -sf http://localhost:2369 && echo "Ghost GGG OK"
curl -sf http://localhost:2370 && echo "Ghost Nursery OK"
```

---

## Teardown

```bash
# Via Make (destroys Droplet + volume)
make tf-destroy env=sandbox

# Or remove the "qa" label from the PR and let the reaper handle it
# (reaper runs every 6 hours; Droplets > 24h old are destroyed automatically)
```

---

## Rollback

To redeploy a previous image/commit:

```bash
# 1. Find the SHA you want to roll back to
git log --oneline -10

# 2. Update terraform.tfvars with the old SHA
#    git_sha = "<old-sha>"

# 3. Re-apply (Terraform will destroy the old Droplet and create a new one
#    because user_data changed)
make tf-apply env=sandbox

# For production rollbacks: update the git_sha variable and apply.
# The new Droplet boots with the old SHA cloned and stack started.
```

---

## Production Deploy

> DANGER: production changes affect live customer traffic.

```bash
# 1. Get peer review + approval on the Terraform PR
# 2. Merge to main
# 3. Apply with explicit CONFIRM flag
export DIGITALOCEAN_TOKEN=<token>
export AWS_ACCESS_KEY_ID=<spaces-key>
export AWS_SECRET_ACCESS_KEY=<spaces-secret>

make tf-init env=production
make tf-plan env=production          # Review the plan carefully
make tf-apply env=production CONFIRM=yes
```

**First-time production bootstrap** (after `terraform apply` creates the Droplet):

```bash
ssh root@<PROD_IP>
git clone https://github.com/Goldberry-Playground/odoocker-goldberrygrove.git /opt/grove
cd /opt/grove
cp .env.example .env && cp .env.grove.example .env.grove
# Edit .env: APP_ENV=production, strong passwords, ACME_CA_URI=production
# Edit .env.grove: real Ghost URLs, CUSTOM_MODULES_REPO

docker compose \
  -f docker-compose.yml \
  -f docker-compose.override.grove.yml \
  -f docker-compose.override.production.yml \
  --profile odoo --profile postgres --profile ghost \
  --profile nginx --profile proxy --profile acme --profile git-sync \
  up -d
```

---

## Follow-ups

### Sandbox Seeders (Sprint 4 W1.5 or W2)

The `.github/workflows/sandbox-deploy.yml` currently runs a placeholder seeder step. The actual seeders to run after cloud-init completes are:

- `grove-odoo-modules/scripts/seed_payment_journals.py`
- `grove-odoo-modules/scripts/seed_sales_teams.py`

Both scripts are idempotent and were committed in Sprint 2 (May 1). Integration will involve:

1. SCP the seeder scripts to the Droplet
2. Run via `docker exec` against the running Odoo container

---

## Cost Estimate

Prices are DigitalOcean nyc3 list rates as of 2025 (subject to change).

| Resource | Spec | $/month |
|----------|------|---------|
| App Droplet | s-4vcpu-8gb | $48 |
| App volume | 100 GB block storage | $10 |
| Monitoring Droplet | s-2vcpu-4gb | $24 |
| Monitoring volume | 20 GB block storage | $2 |
| DO Spaces (state) | 250 GB + transfer | ~$5 |
| Bandwidth overage | Estimate | ~$17 |
| **Total (production)** | | **~$106/month** |

Sandbox Droplets (s-4vcpu-8gb + 50 GB volume): ~$0.096/hour. A 24-hour sandbox costs ~$2.30.
