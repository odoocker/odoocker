# Grove observability — DO App Platform metrics bridge

Ships DigitalOcean **App Platform** CPU%, memory%, and restart count into
OpenObserve as OTLP metrics. This is the one USE-metrics gap the OTel Collector
can't cover: `docker_stats` reads per-container CPU/RAM on the Odoo droplet, but
the Next.js frontends run on App Platform — no host, no Docker socket, no
OTel-native export. Their utilization lives only behind the DO Monitoring API
(spec `docs/specs/2026-06-26-grove-observability-design.md` §5).

The **cost** half of the DO poller is `cost/do_billing_bridge.py` (§6). Both hit
the DO API; they're split because cost is invoice-grained (hourly is plenty)
while USE wants recent, fine-grained saturation + crash-loop signal.

## How it works

```
supercronic (crontab, every 2 min)
   └─ do_metrics_bridge.py
        ├─ GET /v2/apps                                   → app inventory {id, name}
        ├─ for each app × {cpu,memory,restart}:
        │    GET /v2/monitoring/metrics/apps/<metric>?app_id&start&end
        │    → keep the LATEST point per component instance
        └─ POST OTLP gauges → OpenObserve
```

Metrics (queried by the `app-*` alerts + the rightsizing dashboard):

| Metric | Source endpoint | Tags |
|---|---|---|
| `do_app_cpu_percentage` | `metrics/apps/cpu_percentage` | `app`, `component`, `instance`, `env` |
| `do_app_memory_percentage` | `metrics/apps/memory_percentage` | `app`, `component`, `instance`, `env` |
| `do_app_restart_count` | `metrics/apps/restart_count` | `app`, `component`, `instance`, `env` |

`do_app_restart_count > 0` recently is the crash-loop signal (`app-restarts-warning`).

## Scope — App Platform only (by design)

- **Managed Postgres** is *not* here: DO's monitoring API exposes DBaaS metrics
  for **MySQL only** (`metrics/database/mysql/*`), not Postgres. Grove's Postgres
  USE comes from the `postgresql` OTel receiver instead (connects as a client —
  see `otel/README.md`).
- **Droplet** USE comes from the Collector's `hostmetrics`. Not duplicated here.

## Gating

OFF unless `DO_METRICS_ENABLED=true` **and** `DO_API_TOKEN` is set (a **read-only**
DO token with `monitoring:read`). Cloud-only — there are no App Platform apps to
poll locally, so it's a no-op in local dev.

## Run / debug

```bash
# Whole monitoring stack (bridge comes up under the monitoring compose):
make monitoring-up

# One-off, against a running OpenObserve:
DO_METRICS_ENABLED=true DO_API_TOKEN=dop_v1_... COST_ENV=prod \
OPENOBSERVE_OTLP_METRICS_URL=http://localhost:5080/api/default/v1/metrics \
OPENOBSERVE_ROOT_EMAIL=... OPENOBSERVE_ROOT_PASSWORD=... \
python3 do_metrics_bridge.py

# Unit-test the parser + OTLP builder (no token / network needed):
python3 test_do_metrics_bridge.py
```

> **Pending live validation:** the App Platform metric endpoints + matrix
> response shape (`data.result[].values[[ts, "val"]]`) are the documented DO API
> contract (verified against the public OpenAPI spec), but the end-to-end
> poll → OTLP ingest hasn't run with a real token yet — confirm the resulting
> stream/field names on first enable and adjust the `app-*` alert `stream`s if
> needed. **Follow-up:** an App Platform USE panel row on the CostOps dashboard
> (mirrors the droplet/container rightsizing panels).
