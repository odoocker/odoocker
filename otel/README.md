# Grove OTel Collector — USE / infra metrics

Ships the "how hard is each resource working" half of observability (spec §3):
host CPU/RAM/disk/network + per-container CPU/RAM → OpenObserve, as OTLP metrics.
Joined with the cost-bridge's `cost_resource_*`, this is what turns the CostOps
dashboard from "what's expensive" into "what's expensive **and idle**" (§6).

## How it works

```
beyla (eBPF, Odoo) ──OTLP──┐
                           ▼
otel-collector (contrib image)
  receivers:  hostmetrics (/hostfs) + docker_stats (docker.sock) + otlp (from Beyla)
  processors: resourcedetection → resource (env label) → batch
  exporter:   otlphttp → OpenObserve (basicauth)   [metrics + traces pipelines]
```

The Collector is the single auth'd egress: agents (Beyla, and future Next.js
OTel) export to it plain over the internal network; it adds OpenObserve auth once.

- Runs on the **app/Odoo droplet** (where `/proc` + the Docker socket live).
  The App Platform frontends have no `docker_stats` — their USE metrics come from
  the **DO-metrics bridge** (`do-metrics/`, polls the DO Monitoring API →
  `do_app_*` gauges + `app-*` alerts).
- `OPENOBSERVE_OTLP_BASE` targets local `openobserve:5080/api/default` by default;
  point it at the obs droplet (`https://oo.qa-l3.…/api/default`) in QA/prod.

## Alerts (in `openobserve/alerts.json`)

**USE:** `droplet-cpu-{warning,critical}` (>70/90%), `container-ram-{warning,critical}`
(>80/95% of limit), `disk-data-{warning,critical}` (>75/90% — tighter because
MinIO/Postgres-WAL fail catastrophically when full).

**RED (Beyla):** `odoo-orders-latency-{warning,critical}` (p95 >3s/8s),
`odoo-products-latency-warning` (p95 >1s), `odoo-error-rate-warning` (5xx >1%).

## Beyla (eBPF RED for Odoo)

`grafana/beyla` (privileged + `pid: host`) attaches eBPF probes to the Odoo
process by listen port (8069) and emits RED metrics per HTTP route — **zero Odoo
code**. Exports OTLP to `otel-collector:4318`. Single sidecar (Odoo only —
Managed Postgres has no kernel access; its stats come from the `postgresql`
receiver). Needs a Linux host + compatible kernel; if it can't attach it logs
and produces no metrics (never crashes the stack).

## Enabling the `postgresql` receiver (opt-in)

The receiver is **defined-but-commented** and kept out of the pipeline on purpose
— an unset `POSTGRES_*` would fail collector startup and take the USE/RED metrics
down with it. The `postgres-connections-{warning,critical}` alerts + `POSTGRES_*`
env are already staged. To turn it on:

1. `CREATE USER otel_monitor PASSWORD '…'; GRANT pg_monitor TO otel_monitor;`
   (Managed PG under ADR-007 → point `POSTGRES_ENDPOINT` at the managed host.)
2. Set `POSTGRES_ENDPOINT` / `POSTGRES_MONITOR_USER` / `POSTGRES_MONITOR_PASSWORD`
   in `.env.monitoring` (already passed to the container).
3. Uncomment the `postgresql` receiver in `otelcol-config.yaml` **and** add
   `postgresql` to the metrics pipeline `receivers:` list.

## Not yet (documented follow-ups)

- **Next.js `instrumentation.ts`** (grove-sites) → the `nextjs-*` latency + 5xx
  alerts + BFF→Odoo trace correlation. Separate PR (different repo).
- **Rightsizing join panel** — a computed `cost × utilization` JOIN on the Grove
  CostOps dashboard once these metric stream/field names are confirmed live.

> **Pending live validation:** the OpenObserve OTLP endpoint/auth and the exact
> resulting stream/field names (`system_cpu_utilization`, `container_memory_percent`,
> `system_filesystem_utilization`) are the documented shapes but unexercised —
> confirm on first `make monitoring-up` and adjust the exporter + alert `stream`s.
