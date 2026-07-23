# qa-app-platform — Level 3 QA env

The new QA shape from [ADR-007](../../../../docs/ADR/007-level-3-app-platform-migration.md): App Platform for frontends, Managed Postgres, tiny Odoo droplet.

## Status (Phase 1 — TF scaffold)

| Phase | Scope | Status |
|---|---|---|
| **1** | TF scaffold: Managed PG + Odoo droplet + Caddy + DNS + firewall + volume | ✅ merged (#133) |
| **1.5** | Observability droplet + OpenObserve + Keep + inline MinIO | ✅ merged |
| **2** | App Platform app specs (4 frontends) | ✅ applied 2026-07-02 (#157, #158) |
| **3** | Soak validation | ✅ cut short by operator decision 2026-07-04 — L3 healthy, monolith pipeline was consuming all maintenance attention |
| **4** | DNS cutover (qa-l3 → qa subdomain) | ✅ accelerated 2026-07-04 — this env re-keyed to plain `qa`; monolith released the zone |
| **5** | Decommission monolith QA env | ✅ torn down 2026-07-04 (accelerated; cushion waived by operator) — droplet destroyed, `../qa/` deleted |

Phase 1 lands the **bones** of the env. Nothing in this PR is applied yet — applying happens after Phase 1.5 (obs) lands so we don't deploy half the failure-domain story.

## What's in this directory

| File | Purpose |
|---|---|
| `versions.tf` | TF + provider version constraints (mirrors monolith QA) |
| `variables.tf` | All inputs; sensitive ones flow via `TF_VAR_*` from 1Password |
| `main.tf` | Odoo droplet, Managed PG cluster, SSH keys, DNS, firewall, Caddy volume |
| `observability.tf` | Obs droplet + DNS for oo/keep subdomains + obs firewall |
| `apps.tf` | App Platform apps (Phase 2). Starts with hub; other 3 frontends follow. |
| `outputs.tf` | Droplet IPs, Odoo URL, OpenObserve URL, Keep URL, PG cluster ID, App URLs |
| `cloud-init.yaml.tpl` | Stripped to Odoo + Caddy only; wires Managed PG via env |
| `cloud-init-obs.yaml.tpl` | Obs droplet bring-up: docker + MinIO + OpenObserve + Keep + Caddy |
| `compose/docker-compose.qa.yml` | Two services: caddy + odoo. No postgres, no frontends |
| `compose/docker-compose.obs.yml` | Obs stack: minio + openobserve + keep + caddy |
| `compose/Caddyfile.tpl` | Single hostname (`odoo.qa-l3.<apex>`) — Caddy fronts only Odoo |
| `compose/Caddyfile-obs.tpl` | Two admin-only hostnames (`oo.qa-l3.<apex>`, `keep.qa-l3.<apex>`) |
| `terraform.tfvars.example` | Non-sensitive overrides; documentation only (sensitive via env) |
| `backend.hcl.example` | Remote state config; copy + fill in for `terraform init` |

## Key architectural differences vs monolith QA (`../qa/`)

| Concern | Monolith QA | Level 3 QA |
|---|---|---|
| Postgres | Container on droplet | DO Managed Postgres (separate, private network) |
| Frontends | 4 containers on droplet | DO App Platform apps (Phase 2) |
| Caddy hostnames | apex + 4 tenants (5 LE identifiers) | 1 hostname (`odoo.qa-l3.<apex>`) |
| Droplet size | s-2vcpu-4gb (~$24/mo) | s-1vcpu-2gb (~$12/mo) |
| Cert resilience layers | PR-A/B/C/D + cron + multi-issuer fallback | Mostly inert — single hostname, 2 LE renewals/year |
| Failure-domain coupling | One droplet = everything dies together | Per-app + DB independent |

## Cost (Phase 1 only — no App Platform yet)

| Resource | Cost |
|---|---|
| Managed Postgres (db-s-1vcpu-1gb dev tier) | ~$15/mo |
| Odoo droplet (s-1vcpu-2gb) | ~$12/mo |
| Obs droplet (s-1vcpu-2gb) | ~$12/mo |
| Caddy /data volume (1GB) | ~$0.10/mo |
| **Phases 1 + 1.5 total while running** | **~$39/mo** |

Phase 2 adds 4 × $5 basic App Platform apps (~$20/mo) → **~$59/mo full env** (matches the ADR-007 addendum revised estimate of ~$60/mo for QA).

During the Phase 3 parallel-cutover validation window, expect ~$83/mo total (monolith QA $24 + Level 3 $59). The monolith retires in Phase 5.

## Applying

NOT YET APPLIED. The Phase 1.5 PR (next) adds the obs droplet so we don't ship half the failure-domain story. After Phase 1.5 merges:

```bash
# From the repo root
make qa-l3-init   # (target wired in Phase 5; for now use `terraform init` directly)
make qa-l3-apply
```

For now (Phase 1 review only), validate the TF locally:

```bash
cd infra/terraform/environments/qa-app-platform
terraform init -backend=false   # local validation; no real state needed
terraform validate
terraform fmt -check -recursive
```

## SSH access

Same two-key pattern as monolith QA:
- `grove-qa-l3-deploy` — long-lived CI key (TF-managed)
- `grove-qa-admin` — operator key (out-of-band; TF data source reference)

Both attached to the Odoo droplet. The CI key is reused from the monolith env's CI flow (same public-key string).

## Why a new directory instead of evolving `qa/` in place

ADR-007 D4 explicitly chose parallel cutover. The monolith QA must keep running through Phase 3 validation so we have a working fallback if anything in Level 3 misbehaves. Two TF envs = two state files = two `terraform apply` cycles that can't accidentally clobber each other.

After Phase 5 decommissions the monolith, Phase 5 also renames `qa-app-platform/` → `qa/` so the directory name stays canonical.
