# ADR 008: OpenObserve + Keep is the canonical observability stack (supersedes ADR-004's Phase-11 plan)

**Status:** Accepted
**Date:** 2026-06-26
**Deciders:** Josh Dunbar
**Supersedes:** the "Observability" section of [ADR-004](./004-qa-promotion-model.md) (Loki + Prometheus/Grafana + Sentry, deferred to its Phase 11)
**Reference design:** `docs/specs/2026-06-26-grove-observability-design.md`

## Context

Two observability visions currently coexist in the repo:

1. **Shipped (GATH-44):** **OpenObserve** (single binary — synthetic monitors + logs/metrics/traces + alerting + dashboards, Parquet on MinIO, AGPL-3.0) **+ Keep** (alert routing → Discord). Documented in `docs/MONITORING.md` + `docker-compose.monitoring.yml`. It deliberately replaced the original *LGTM + Uptime Kuma + Plausible* plan on cost grounds.

2. **Planned, never built:** ADR-004's "Observability" section lists **Loki + Prometheus/Grafana/cadvisor/node-exporter + Sentry**, deferred to its Phase 11.

These conflict. Leaving both in place means "what is Grove's observability stack?" has two contradictory answers — exactly the single-source-of-truth failure mode ADR-004 itself was written to prevent (for deploy state).

## Decision

**OpenObserve + Keep is the canonical Grove observability stack.** ADR-004's Phase-11 Loki/Prometheus/Grafana/Sentry plan is **superseded** and will not be built as specified. The functional equivalents are delivered within OpenObserve + Keep:

| ADR-004 Phase-11 tool | Superseded by |
|---|---|
| Loki (log aggregation) | OpenObserve logs (Parquet-on-MinIO) |
| Prometheus + Grafana + cadvisor + node-exporter (metrics + dashboards) | OpenObserve metrics + dashboards, fed by an OTel Collector (hostmetrics + docker_stats) |
| Sentry (frontend errors) | OpenObserve RUM (JS errors + Web Vitals) |

The full functional design — synthetic journeys, RUM, APM/infra (eBPF-first via Beyla), the resilient prod deployment, the dead-man's-switch, and the ADR-004-governed promotion — lives in `docs/specs/2026-06-26-grove-observability-design.md`.

## Why

- **One source of truth.** A single stack the whole pipeline references, consistent with ADR-004's own principle.
- **Cost.** OpenObserve consolidates what LGTM needs 4+ services for; $0 software, no per-host/seat pricing. Same rationale that drove GATH-44.
- **It already shipped and is governed.** The stack exists, is config-as-code (`openobserve/monitors.json`, `alerts.json`, `keep/workflows.yml`), and folds into the `release-manifest.yaml` promotion model (design spec §6).

## Consequences

**Positive:**
- ADR-004's observability section is no longer a contradictory backlog item; it points here.
- The design spec's three-independent-alert-paths + dead-man's-switch resilience model replaces "Loki/Prometheus/Sentry, deferred."
- No new tools to learn beyond OpenObserve + Keep (+ Beyla, OTel Collector, Healthchecks — all open-source emitters/routers around the same core).

**Negative / open:**
- Sentry's mature frontend-error ergonomics (release tracking, source-map decoding) are richer than OpenObserve RUM today. Accepted; revisit only if RUM error triage proves insufficient (design spec defers the explicit-SDK depth the same way).
- ADR-004's body still contains the old observability prose; it is superseded by this ADR, not edited in place (ADRs are immutable records). Readers follow the supersession pointer.

## References

- [ADR-004](./004-qa-promotion-model.md) — QA promotion model (observability section superseded here)
- [ADR-007](./007-level-3-app-platform-migration.md) — the topology this observability deploys onto
- `docs/MONITORING.md` — operator guide for the shipped OpenObserve + Keep stack
- `docs/specs/2026-06-26-grove-observability-design.md` — the full functional + deployment design
