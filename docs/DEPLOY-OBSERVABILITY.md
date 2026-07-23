# Deploying the Grove observability stack to production

The observability stack (OpenObserve + Keep + the synthetic / cost / do-metrics
bridges + OTel Collector + Beyla, plus self-hosted Plausible) is a **separate
failure domain from the app plane** (ADR-007 / ADR-008): if the Odoo droplet and
the frontends go down, monitoring keeps running and pages you. It therefore runs
on its **own droplet**, deployed and operated independently of the app stack.

> **It is NOT part of `qa-deploy`.** The QA pipeline never brings up an
> observability container (`monitoring = false` on the QA droplet), and
> `sync-qa-on-main-push` skips `scripts/setup-monitoring.py` and
> `infra/terraform/environments/production/*`. The one gated `qa-deploy` step
> (`if: env.OPENOBSERVE_BASE_URL != ''`) only *POSTs config* to an already-running
> obs instance, and is skipped while `OPENOBSERVE_BASE_URL` is unset. Observability
> is a **prod concern**; QA works without it.

---

## Topology

```
obs droplet (separate from the Odoo/app droplet)
├── docker-compose.monitoring.yml   OpenObserve + Keep + bridges + OTel Collector (+ Beyla on the Odoo droplet)
└── docker-compose.plausible.yml    Plausible CE + its own Postgres + ClickHouse   (prod only)

Storage:  OpenObserve Parquet → DO Spaces (S3)      ┐ durable, survives droplet recreate
          Keep SQLite, Plausible PG/ClickHouse      ┘ → DO block volume (see "Storage")
```

Beyla runs as a privileged sidecar **on the Odoo droplet** (it needs kernel
access to the Odoo process); everything else runs on the obs droplet.

---

## What must be decided before prod (open items)

These aren't code — they're calls to make + live infra to apply:

1. **Separate vs shared obs instance.** ADR-007 §4 favors a *separate* prod obs
   droplet (isolation) over sharing the QA-L3 instance. If separate, add
   `infra/terraform/environments/production-observability/` (copy the
   `observability` env, prod firewall + sizing). ~$24/mo for the extra droplet.
2. **Apply the terraform.** `infra/terraform/environments/observability/` is a
   reviewed scaffold, **not yet applied**. Validate it with a live apply on a
   throwaway droplet first, then provision the real obs droplet.
3. **Secrets pipeline.** Wire Infisical → terraform/cloud-init → compose env
   (same OIDC pattern as `qa-app-platform`), so the values below never live in a
   committed file. Until that exists, provision `.env.monitoring` / `.env.plausible`
   on the droplet by hand from the checklist below.
4. **Storage volumes.** Attach DO block volumes for Keep's SQLite and Plausible's
   databases; point OpenObserve at DO Spaces. See "Storage".

---

## Prod env contract

Copy `.env.monitoring.example` → `.env.monitoring` and `.env.plausible.example` →
`.env.plausible` on the droplet and fill these in. **Nothing may keep its example
value in prod.**

### Required — `docker-compose.monitoring.yml`

| Var | Prod value | Notes |
|-----|-----------|-------|
| `OPENOBSERVE_TAG` / `KEEP_TAG` | pinned (e.g. `v0.17.2` / `v0.54.1`) | never `:latest` — pinned in the example + `release-manifest.yaml` |
| `OPENOBSERVE_ROOT_EMAIL` / `OPENOBSERVE_ROOT_PASSWORD` | real | password: `openssl rand -base64 24` — **not** the `ChangeMe_…` example |
| `OPENOBSERVE_LOCAL_MODE` | `true` (single-node) | set `false` + add etcd only if you need HA |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` **or** DO Spaces keys | real | OpenObserve Parquet storage backend |
| `KEEP_AUTH_TYPE` | `NO_AUTH` **only if** Keep is admin-firewalled; else a real mode | public Keep UI without auth = open dashboard |
| `KEEP_WEBHOOK_TOKEN` | `openssl rand -hex 32` | bearer on OpenObserve→Keep ingest |
| `KEEP_NEXTAUTH_SECRET` | `openssl rand -hex 32` | Keep session secret |
| `DISCORD_WEBHOOK_WARNING` / `DISCORD_WEBHOOK_CRITICAL` | real webhook URLs | from 1Password; alerts silently drop if wrong |

### Required — `docker-compose.plausible.yml`

| Var | Prod value |
|-----|-----------|
| `PLAUSIBLE_TAG` | pinned (`v3.2.1`) |
| `PLAUSIBLE_BASE_URL` | `https://plausible.gatheringatthegrove.com` (must match the frontends' `NEXT_PUBLIC_PLAUSIBLE_HOST`) |
| `PLAUSIBLE_SECRET_KEY_BASE` | `openssl rand -base64 48` |
| `PLAUSIBLE_TOTP_VAULT_KEY` | `openssl rand -base64 32` |
| `PLAUSIBLE_POSTGRES_PASSWORD` | strong, unique |

### Optional bridges — all-or-nothing

Each is **off by default** and now **fails loudly** if you enable it without its
required config (it logs `✗ …ENABLED=true but …_TOKEN is unset — misconfigured`
instead of silently producing no metrics). Enable a feature only with its full
config:

| Feature | Enable | Also requires |
|---------|--------|---------------|
| Cost bridge | `COST_BRIDGE_ENABLED=true` | `DO_API_TOKEN` (read-only), `COST_MONTHLY_BUDGET` |
| DO App-Platform metrics | `DO_METRICS_ENABLED=true` | `DO_API_TOKEN` (read-only) |
| Synthetic checkout-canary | `SYNTHETIC_CANARY_ENABLED=true` | `ODOO_DB`, `ODOO_LOGIN`, `SYNTHETIC_ODOO_API_KEY` |
| Synthetic ghost-content | `SYNTHETIC_GHOST_ENABLED=true` | `GHOST_URL_*` + `GHOST_KEY_*` per tenant |
| Postgres USE receiver | uncomment in `otel/otelcol-config.yaml` | `POSTGRES_ENDPOINT` + read-only `pg_monitor` creds |
| Beyla (Odoo RED) | on by default on the Odoo droplet | Linux host + compatible kernel (no-op otherwise) |

### Frontend tracing / RUM (grove-sites — server + client)

Set per app, then rebuild/redeploy the frontends:

- Server tracing (`@grove/otel`): `OTEL_SERVICE_NAME=grove-<tenant>`,
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://<oo>/api/default/v1/traces`,
  `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <b64(email:password)>` (server-side only).
- Client RUM (`@grove/analytics`): `NEXT_PUBLIC_RUM_ENABLED=true`, the
  `NEXT_PUBLIC_OO_RUM_*` client token/site, and `NEXT_PUBLIC_PLAUSIBLE_HOST` +
  `NEXT_PUBLIC_PLAUSIBLE_DOMAIN`.

---

## Storage (durability)

Named Docker volumes are **lost when the droplet is recreated**. For prod:

- **OpenObserve** → DO **Spaces** (S3-compatible). Set `ZO_S3_*` to the Spaces
  endpoint/bucket/keys instead of the local MinIO `s3` service. This is the bulk
  of the data and the main durability win.
- **Keep SQLite** (`keep-data`) → a small attached **DO block volume**. Holds the
  Discord/OpenObserve provider config + workflow state. Losing it means re-running
  `setup-monitoring.py` (idempotent, so recoverable, but the volume avoids it).
- **Plausible** (`plausible-db-data`, `plausible-event-data`) → an attached **DO
  block volume**; ClickHouse is write-heavy. This is your marketing history — no
  synthetic source to rebuild it from. Snapshot it on a schedule.

Treat the obs droplet as **permanent infrastructure**: `terraform plan` before any
change, don't casually recreate.

---

## Go-live checklist

1. [ ] Decide separate vs shared obs instance; if separate, create the prod
       terraform env.
2. [ ] Validate `infra/terraform/environments/observability` with a live apply on
       a throwaway droplet; fix anything that only shows up live.
3. [ ] Provision the obs droplet (Spaces-backed OpenObserve; block volumes for
       Keep + Plausible).
4. [ ] Fill `.env.monitoring` + `.env.plausible` per the contract above — generate
       every secret, no example values. Pin every image tag.
5. [ ] `KEEP_AUTH_TYPE`: leave `NO_AUTH` only if the firewall restricts Keep to
       admins; otherwise set a real auth mode.
6. [ ] Bring the stacks up on the droplet:
       `docker compose -f docker-compose.monitoring.yml --env-file .env.monitoring up -d`
       and the Plausible stack likewise.
7. [ ] Point `OPENOBSERVE_BASE_URL` / `KEEP_BASE_URL` at the droplet in Infisical,
       then run `scripts/setup-monitoring.py` (or let the gated `qa-deploy`/prod
       step run it) to POST monitors + the 37 alerts + dashboards.
8. [ ] In Plausible: register a site per tenant domain, wire the Caddy route
       `plausible.<domain>` → `plausible:8000`.
9. [ ] Flip the frontends on: `NEXT_PUBLIC_RUM_ENABLED=true` + the `OTEL_*` server
       vars + the OpenObserve RUM client token; redeploy.
10. [ ] Smoke test: kill a canary container and confirm a Discord alert lands
        (`scripts/smoke-test-monitoring.sh`), and confirm traces/RUM/cost streams
        populate in OpenObserve.

---

## Pending-validation note

Every "stream/field name pending live validation" caveat in `alerts.json`,
`otelcol-config.yaml`, and the bridge READMEs clears on the first real prod
traffic — the shapes are the documented OTLP/OpenObserve contracts but haven't
been exercised end-to-end with a live instance yet. Step 10 is where they get
confirmed; adjust the alert `stream` names if the live field names differ.
