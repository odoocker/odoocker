# Grove Monitoring

Operator guide for the OpenObserve + Keep monitoring stack shipped in GATH-44.

> **Why this shape, not LGTM + Uptime Kuma?** The original GATH-44 spec called for the LGTM (Loki + Grafana + Tempo + Mimir) stack plus Uptime Kuma. After cost-conscious review (`grill-me` session 2026-06-09), we pivoted to OpenObserve (consolidates LGTM + Uptime Kuma + native alerting into one binary, AGPL-3.0 self-hosted, zero per-host pricing) and Keep (open-source AIOps alert routing). Discord webhooks replace Slack/PagerDuty for the solo-dev tier.

## Stack at a glance

| Service | Port (host) | What it does |
|---|---|---|
| **OpenObserve** | `5080` | Synthetic HTTP/TCP monitors, threshold alerts, logs/metrics/traces ingestion, dashboards. Parquet-on-MinIO storage. |
| **Keep backend** | `8080` | Alert dedup + severity-based routing. Receives OpenObserve webhooks, fires Discord. |
| **Keep frontend** | `3034` | UI for viewing alert state, manually firing test alerts, editing workflows. |

Both services join the existing `gatheratthegrove_internal` Docker network so OpenObserve can probe internal-only services (Postgres TCP) via service-name DNS.

## Quickstart

```bash
# 1. Configure
cp odoocker/.env.monitoring.example odoocker/.env.monitoring
# Edit .env.monitoring:
#   - Paste your Discord warning + critical webhook URLs
#   - Replace the dev-default Keep tokens with `openssl rand -hex 32`
#   - Rotate OPENOBSERVE_ROOT_PASSWORD

# 2. Bring up the main stack first (monitoring has nothing useful to monitor without it)
make all-up

# 3. Bring up monitoring + bootstrap configs in one command
make monitoring-up
```

After step 3:
- **OpenObserve UI**: http://localhost:5080 (log in with `OPENOBSERVE_ROOT_EMAIL` + password from `.env.monitoring`)
- **Keep UI**: http://localhost:3034 (no auth in dev mode)

The bootstrap script:
- Uploads 20 synthetic monitors (4 frontends × 1-3 routes + Odoo + 3 Ghosts + Postgres + 4 SSL placeholders)
- Uploads 7 alert rules with severity tags
- Uploads 1 status-page dashboard
- Configures Keep's 2 Discord providers + 3 workflows

Idempotent — re-run safe.

## Daily operations

| Task | Command |
|---|---|
| Check what's currently alerting | http://localhost:5080/web/alerts |
| Test the wiring end-to-end | `./scripts/smoke-test-monitoring.sh` |
| Update monitors after editing JSON | `make monitoring-setup` |
| Update Keep workflows after editing YAML | `make monitoring-setup` |
| View Discord routing config | http://localhost:3034/providers |
| Tail container logs | `make monitoring-logs` |
| Stop the stack (preserves Parquet) | `make monitoring-down` |

## Verifying the GATH-44 acceptance

```bash
./scripts/smoke-test-monitoring.sh
```

This script:
1. Sends a connectivity-check alert through Keep → Discord warning channel (confirms wiring works before any destructive action)
2. Captures pre-kill timestamp
3. `docker kill gatheratthegrove-odoo-1`
4. Polls OpenObserve for the `odoo-down-critical` alert to fire
5. Restores Odoo
6. Asserts: alert fired within 120 seconds

PASS → GATH-44 acceptance criterion verified. The Discord critical channel should contain an `@here` ping with a runbook link to `docs/RUNBOOKS.md#odoo-down`.

## Editing monitors

Monitors are config-as-code in `openobserve/monitors.json`. Schema:

```json
{
  "name": "unique-monitor-name",
  "type": "http" | "tcp" | "ssl",
  "url": "http://host:port/path",       // http only
  "host": "hostname", "port": 5432,     // tcp/ssl only
  "method": "GET" | "POST",             // http only
  "expected_status": 200,               // http only — exact match
  "expected_status_in": [200, 401],     // http only — set match
  "expected_keyword": "literal string", // http only — body contains
  "interval_seconds": 30,
  "timeout_seconds": 10,
  "alert_days_before_expiry": 14,       // ssl only
  "tags": ["tenant:X", "tier:Y", "service:Z"]
}
```

After editing, re-run `make monitoring-setup` to upsert.

## Editing alerts

Alerts are config-as-code in `openobserve/alerts.json`. Each alert references a monitor (or set of monitors) and a trigger condition. Severity (`warning` | `critical`) maps to Keep workflows (`workflows.yml`) which select the Discord channel.

After editing, `make monitoring-setup`.

## Editing Discord routing

Two layers:
1. **Providers** (`keep/providers.yml`) — which webhooks to call (warning channel, critical channel). Edit the channel→URL mapping here.
2. **Workflows** (`keep/workflows.yml`) — which severity goes to which provider, message template, rate-limiting.

After editing, `make monitoring-setup`.

## Synthetic Tier-1 (Hurl)

Beyond the built-in OpenObserve monitors (shallow HTTP/TCP/SSL up-checks), the
`synthetic-runner` container runs **multi-step Hurl journeys** against the live
`grove_headless` API every 60s (supercronic) and ships pass/fail + latency to
OpenObserve as OTLP metrics. See `synthetic/README.md` for the full design.

| Journey | Scope | Proves |
|---|---|---|
| `health` | shared | grove_headless API up |
| `catalog` | per tenant | products list + detail (with price) work |
| `cart-flow` | per tenant | add-to-cart → cart reflects the line (BFF↔Odoo write path) |
| `checkout-canary` | per tenant (opt-in) | $0 order via bearer `/orders` + access_token gate; draft swept via XML-RPC |
| `ghost-content` | per tenant (opt-in) | Ghost Content API v5 returns ≥1 published post |

Metrics emitted (queried by the `synthetic-*` alert rules in `alerts.json`):
- `synthetic_journey_success` — gauge 1/0, tags `{journey, tenant, tier=api, env}`
- `synthetic_journey_duration_ms` — gauge ms

```bash
# Journeys live in synthetic/journeys/*.hurl (edit + the runner picks them up
# on its next minute). Add/remove journeys in synthetic/run.py's journey lists.
# Unit-test the metric shipper without the stack:
python3 synthetic/test_run.py
```

**Opt-in money-path journey:** `checkout-canary` is OFF by default. Set
`SYNTHETIC_CANARY_ENABLED=true` + `ODOO_DB`/`ODOO_LOGIN`/`SYNTHETIC_ODOO_API_KEY`
to enable it — `setup-monitoring.py` then seeds an unpublished `$0 SYNTHETIC-CANARY`
product and the runner creates/sweeps a draft order each cycle (see
`synthetic/README.md`).

**Opt-in content journey:** `ghost-content` is OFF by default. Set
`SYNTHETIC_GHOST_ENABLED=true` + per-tenant `GHOST_URL_<TENANT>`/`GHOST_KEY_<TENANT>`
(read-only Content API keys) to check each blog has published posts — content
depth beyond the `ghost-*-admin` availability monitors. **Synthetic Tier-1 is
now complete** (health, catalog, cart-flow, checkout-canary, ghost-content).

## CostOps (DO billing bridge)

The `cost-bridge` container polls the DigitalOcean API hourly and ships **cost as
metrics** into the same OpenObserve pane as the USE/utilization data, so
`cost_resource_monthly_estimate × low-utilization` becomes a **rightsizing /
"what to trim"** view. See `cost/README.md` for the design; spec §6.

| Metric | Meaning |
|---|---|
| `cost_account_month_to_date` / `_balance` / `_month_to_date_usage` | The **actual** aggregate truth from DO's balance API |
| `cost_resource_monthly_estimate{type,name,size,env}` | Per-resource **derived** cost = live inventory × static price list |

Alerts: `cost-budget-warning`/`-critical` (vs `COST_MONTHLY_BUDGET`) and
`cost-anomaly-warning`. **Opt-in + cloud-only** — set `COST_BRIDGE_ENABLED=true`
+ a read-only `DO_API_TOKEN` (no-op locally). **Sprint 2** adds Infracost
(pre-merge `$/mo` delta on Terraform PRs) as the shift-left complement.

**Rightsizing:** the **Grove CostOps** dashboard's *Rightsizing* row correlates
droplet cost (cost-bridge) with droplet/container utilization (OTel Collector USE
metrics) — high cost + low use = a downsize candidate. A single computed
`cost × utilization` JOIN is a follow-up once the metric stream/field names are
confirmed live.

## APM / Infra — OTel Collector (USE metrics)

The `otel-collector` container (contrib image) scrapes **host** CPU/RAM/disk
(`hostmetrics` via `/hostfs`) + **per-container** CPU/RAM (`docker_stats` via the
socket) and ships OTLP metrics to OpenObserve. Config: `otel/otelcol-config.yaml`.

These are the **USE** metrics that complete the CostOps rightsizing view — joined
with the cost-bridge's `cost_resource_monthly_estimate`, `cost × low-utilization`
finally becomes "what to trim." Alerts added: `droplet-cpu-{warning,critical}`,
`container-ram-{warning,critical}`, `disk-data-{warning,critical}`.

Always on (reuses the OpenObserve root creds; no extra secret). Point
`OPENOBSERVE_OTLP_BASE` at the obs-droplet URL in QA/prod. **Follow-ups:** the
`postgresql` receiver (documented-optional in the config → `postgres-connections`
alert) and Beyla eBPF for the RED latency/5xx alerts.

## Cost model

- **Local:** $0. OpenObserve + Keep + MinIO all self-hosted.
- **Preview (M2)**: $0 incremental. OpenObserve joins the per-PR droplet; Parquet writes to DO Spaces (which Bootstrap TF already provisions — $5/mo for 250GB shared across all envs).
- **Production (M4)**: $0 incremental once the prod droplet exists. Same OpenObserve container, same Discord webhooks.

> No Datadog, no Grafana Cloud, no PagerDuty subscription. Discord's `@here` mechanism substitutes for paid paging on a solo-dev tier.

## What's still aspirational

- **`status.gatheringatthegrove.com` DNS** — production terraform mentions the hostname as a comment (line 162) but no DNS record + no reverse-proxy config. Lands with M2 droplet.
- **SSL cert expiry monitors** — the 4 placeholder monitors are in `monitors.json` but will fail locally because there are no real certs. They become meaningful when M2 droplet provisions Let's Encrypt.
- **Production kill-test** — the acceptance criterion `Killing Odoo in production triggers Slack + PagerDuty in <2 min` requires M2 droplet to exist. Local equivalent (this stack) is the closest verifier today.

## Related

- `docs/RUNBOOKS.md` — one entry per alert
- `openobserve/monitors.json` — synthetic monitor source-of-truth
- `openobserve/alerts.json` — alert rule source-of-truth
- `keep/providers.yml` — Discord webhook definitions
- `keep/workflows.yml` — severity → channel routing
- `scripts/setup-monitoring.py` — bootstrap script (idempotent)
- `scripts/smoke-test-monitoring.sh` — GATH-44 acceptance verifier
