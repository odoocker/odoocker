# Grove Deployment Overview

**TL;DR — which doc do you need?**

| Want to... | Read |
|---|---|
| Run the stack locally (OrbStack + compose) | [`docs/DEVELOPMENT.md`](./DEVELOPMENT.md) |
| Push a feature to QA for human testing | [`infra/terraform/environments/qa/README.md`](../infra/terraform/environments/qa/README.md) |
| Deploy production | [`infra/terraform/environments/production/README.md`](../infra/terraform/environments/production/README.md) — **STUB / DEFERRED** (see below) |
| Set up monitoring (OpenObserve + Keep) | [`docs/MONITORING.md`](./MONITORING.md) |
| Seed Ghost content keys in a fresh QA droplet | [`docs/GHOST.md`](./GHOST.md) |
| Understand the architecture | [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) |

---

## The three deployment targets

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   LOCAL     │  push   │     QA      │  push   │ PRODUCTION  │
│  (laptop)   │   to    │  branch     │   to    │  (deferred  │
│  OrbStack   │ ───qa──▶│  auto-deploy│ ──main─▶│ pending     │
│  compose    │         │  to DO env  │         │ Level 3)    │
└─────────────┘         └─────────────┘         └─────────────┘
   make all-up        sync-qa-on-main →            See ADR-007
                        dispatches qa-deploy.yml
```

---

## 1. Local — `make all-up` on OrbStack

**One-command bring-up of the full stack on your laptop.** Uses Docker Compose with OrbStack as the runtime.

```bash
cd ~/Documents/Dev\ Projects/gather-at-the-grove/odoocker
cp .env.example .env             # one-time; edit for your env
make all-up                      # postgres + odoo + frontends
make monitoring-up               # optional: OpenObserve + Keep (~1GB RAM)
```

URLs:
- Odoo: http://localhost:8069
- Hub: http://localhost:3000
- Tenant frontends: http://localhost:3001-3003
- OpenObserve: http://localhost:5080 (if `monitoring-up`)

Full local dev workflow (module reload, MCP server, Ghost CMS, multi-tenant testing): [`docs/DEVELOPMENT.md`](./DEVELOPMENT.md).

---

## 2. QA — push to `qa` branch (auto-deploys)

**The dev → QA loop is fully automated.** Every push to `main` syncs to `qa` + dispatches a fresh QA deploy. Operators can also dispatch manually.

```
operator merges PR to main
    ↓
.github/workflows/sync-qa-on-main-push.yml
    ├─ force-pushes main → qa
    └─ dispatches qa-deploy.yml on the qa branch
    ↓
.github/workflows/qa-deploy.yml
    ├─ preflight: cloud-init ASCII, GHCR pullable, image shapes, orphan TXT cleanup
    ├─ pre-teardown existing droplet (sidesteps DO's 1m delete timeout)
    ├─ terraform apply (CREATE-only — droplet, volume, attachment, DNS)
    ├─ cloud-init runs on the new droplet: docker install + compose up
    ├─ sentinel polls hub.qa.* until 200 (or 20-min timeout)
    ├─ post-deploy: cert quality upgrade (prefer LE prod over staging)
    └─ post-deploy: Discord URL list
```

Public URLs after deploy (monolith QA):
- `https://hub.qa.gatheringatthegrove.com` (hub frontend)
- `https://goldberry.qa.gatheringatthegrove.com` (tenant)
- `https://ggg.qa.gatheringatthegrove.com` (tenant)
- `https://nursery.qa.gatheringatthegrove.com` (tenant)
- `https://odoo.qa.gatheringatthegrove.com` (Odoo admin)

**Cutover complete (accelerated Phase 4, 2026-07-04):** the `qa.` hostnames above are served by the **Level 3 env** (`infra/terraform/environments/qa-app-platform/`) — App Platform frontends + Managed Postgres + tiny Odoo droplet + obs droplet. The `qa-l3.*` hostnames are retired. Admin URLs live on the same plain zone: `odoo.qa.*`, `oo.qa.*`, `keep.qa.*` (latter two firewall-allowlisted).

The monolith is fully torn down (2026-07-04): droplet destroyed, TF state emptied, env directory + all pipeline workflows deleted. Frontend deploys no longer go through this repo at all: grove-sites CI pushes images to GHCR and the App Platform apps auto-redeploy (`deploy_on_push`); the Odoo/obs droplets redeploy via `terraform apply` in the qa-app-platform env.

### QA fast iteration — soft restart without full deploy

If you need to test a compose / Caddyfile / image-tag change without waiting 15 min for a full deploy:

```bash
make qa-ssh                               # interactive shell on QA droplet
make qa-restart SERVICE=hub               # restart one container
make qa-logs SERVICE=odoo                 # stream container logs
make qa-shell SERVICE=odoo                # shell INSIDE container
make qa-pull-one SERVICE=hub              # pull new image + recreate one service
make qa-reload-caddy                      # docker restart caddy (reload is unreliable)
make qa-edit-caddy                        # scp Caddyfile down → $EDITOR → scp up → restart
make qa-push-compose                      # LOCAL fast-path: rsync compose+Caddyfile, restart (~30s)
```

Hierarchy of iteration speed:
| Level | Tool | Cost |
|---|---|---|
| 1 | `make qa-edit-caddy` / `make qa-reload-caddy` | ~5s |
| 2 | `make qa-restart SERVICE=hub` | ~10s |
| 3 | `make qa-pull-one SERVICE=hub` | ~30s |
| 4 | `make qa-push-compose` | ~30s (local) |
| 5 | `qa-compose-update.yml` workflow | ~2 min (CI with preflight) |
| 6 | full `qa-deploy.yml` (droplet recreate) | ~15 min (TF apply) |

⚠️ Levels 1-4 create TF state drift. Use them to **preview your change quickly**, then PR to `main` to codify (full qa-deploy reapplies from source).

Full QA env details: [`infra/terraform/environments/qa/README.md`](../infra/terraform/environments/qa/README.md).

### Cert quality — self-healing TLS

The QA env has 4 layers of cert resilience (see [`docs/ADR/005-qa-cert-resilience-stack.md`](./ADR/005-qa-cert-resilience-stack.md)):

1. **Persistent Caddy /data** (DO block volume) — cert survives droplet recreates
2. **Multi-issuer fallback** — LE prod first, LE staging if prod 429s
3. **Orphan TXT cleanup preflight** — works around `caddy-dns/digitalocean` plugin's delete bug
4. **Auto-upgrade staging→prod** — `caddy-prefer-prod-cert.yml` cron every 6h detects staging certs (browser-untrusted) and re-requests from prod

End state: deploys never block on cert provisioning. If you ever see a browser warning, the upgrader will fix it within 6 hours (or you can `gh workflow run caddy-prefer-prod-cert.yml` manually).

---

## 3. Production — STUB / DEFERRED pending Level 3

> ⚠️ **Production is not currently deployable.** The TF scaffold at `infra/terraform/environments/production/` is intentionally gated behind a "DO NOT DEPLOY YET" banner.

**Why deferred:** the QA env evolved through 38 PRs in late June 2026 into a self-healing pipeline (cert resilience, soft-restart automation, observability prep). The 2026-06-26 architectural review concluded that production should be built on the **Level 3 shape** (DO App Platform + Managed Postgres + tiny Odoo droplet + obs droplet) rather than the existing monolith pattern. Building prod on the old shape now would create technical debt that Phase 6 of [`docs/ADR/007-level-3-app-platform-migration.md`](./ADR/007-level-3-app-platform-migration.md) will throw away.

**The deferred prod-deploy doc** ([`docs/DEPLOY.md`](./DEPLOY.md)) describes the **pre-Level-3** procedure (nginx + manual ACME via Cloudflare + per-host A records). Useful as historical reference but **do not execute** until Phase 6 ships.

**When production becomes deployable** (per Phase 6 of ADR-007):

```
1. Level 3 QA env (infra/terraform/environments/qa-app-platform/) shipped + validated for ~2 weeks
2. Phase 6 PR rewrites infra/terraform/environments/production/ to use App Platform + Managed PG
3. That same PR removes the "DO NOT DEPLOY YET" banner
4. THEN production deploy procedure becomes valid
```

Status updates appear in [`production/README.md`](../infra/terraform/environments/production/README.md) when this lands.

---

## Cross-cutting documentation

- **Architecture (data flow, BFF pattern):** [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) — describes the pre-Level-3 design; will be updated when Phase 6 ships
- **Monitoring stack (OpenObserve + Keep):** [`docs/MONITORING.md`](./MONITORING.md)
- **Runbooks (oncall):** [`docs/RUNBOOKS.md`](./RUNBOOKS.md)
- **Security:** [`docs/SECURITY.md`](./SECURITY.md)
- **All ADRs:** [`docs/ADR/`](./ADR/)

## Related repos

- [`grove-sites`](https://github.com/Goldberry-Playground/grove-sites) — Next.js 15 monorepo (hub + 3 tenant frontends); built + published to GHCR; consumed here under the `frontends` profile
- [`grove-odoo-modules`](https://github.com/Goldberry-Playground/grove-odoo-modules) — custom Odoo modules; deployed via git-sync; bind-mounted locally for fast iteration
