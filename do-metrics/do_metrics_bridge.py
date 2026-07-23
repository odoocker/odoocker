#!/usr/bin/env python3
"""
Grove observability — DigitalOcean App Platform metrics bridge → OpenObserve.

Closes the one USE-metrics gap the OTel Collector can't reach. The Collector's
docker_stats scrapes per-container CPU/RAM on the Odoo droplet, but the Next.js
frontends run on **App Platform** — no host, no Docker socket, no OTel-native
export. Their CPU%, memory%, and restart count live only behind the DO
Monitoring API, so this poller pulls them and ships OTLP gauges into the same
OpenObserve pane as everything else (spec §5 "DO-metrics bridge"; the §6 cost
half is cost/do_billing_bridge.py — both hit the DO API, different cadence).

Metrics (one gauge point per app component instance, latest sample in-window):
    do_app_cpu_percentage        GET /v2/monitoring/metrics/apps/cpu_percentage
    do_app_memory_percentage     GET /v2/monitoring/metrics/apps/memory_percentage
    do_app_restart_count         GET /v2/monitoring/metrics/apps/restart_count
                                 (>0 recently = crash loop → app-restarts alert)

Managed Postgres is deliberately NOT here — DO's monitoring API exposes DBaaS
metrics for MySQL only, and Grove's Postgres USE already comes from the
`postgresql` OTel receiver (connects as a client). Droplet USE likewise comes
from the Collector's hostmetrics. This bridge is App Platform only.

OFF unless DO_METRICS_ENABLED=true AND DO_API_TOKEN is set. Scheduled every 2
min by supercronic (see ./crontab). Stdlib only; all logs to stderr; exits 0
even on API errors (a metrics gap must never crash the poller).

Env (see .env.monitoring.example):
    DO_METRICS_ENABLED            default false
    DO_API_TOKEN                  read-only DigitalOcean API token (monitoring:read)
    COST_ENV                      default local   (env label on every metric)
    DO_METRICS_LOOKBACK_SECONDS   default 600     (query window; latest point wins)
    OPENOBSERVE_OTLP_METRICS_URL  default http://openobserve:5080/api/default/v1/metrics
    OPENOBSERVE_ROOT_EMAIL/PASSWORD   basic-auth for OpenObserve ingest
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
from urllib import error as urlerror
from urllib import parse, request

DO_API_BASE = "https://api.digitalocean.com"

# DO App Platform metric endpoint → (OTLP metric name, unit).
APP_METRICS = {
    "cpu_percentage": ("do_app_cpu_percentage", "%"),
    "memory_percentage": ("do_app_memory_percentage", "%"),
    "restart_count": ("do_app_restart_count", "{restarts}"),
}


def _log(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def is_enabled() -> bool:
    return _env("DO_METRICS_ENABLED", "false").strip().lower() == "true" and bool(_env("DO_API_TOKEN"))


# ── DO API ───────────────────────────────────────────────────────────────────
def do_get(path: str, params: dict[str, str] | None = None) -> dict:
    url = f"{DO_API_BASE}/{path.lstrip('/')}"
    if params:
        url = f"{url}?{parse.urlencode(params)}"
    req = request.Request(url, headers={"Authorization": f"Bearer {_env('DO_API_TOKEN')}"})
    with request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def fetch_apps() -> list[dict[str, str]]:
    """Live App Platform inventory → [{id, name}]."""
    out: list[dict[str, str]] = []
    for app in do_get("v2/apps", {"per_page": "200"}).get("apps", []):
        spec = app.get("spec", {}) or {}
        out.append({"id": app.get("id", ""), "name": spec.get("name", "?")})
    return out


def fetch_app_metric(app_id: str, endpoint: str, start: int, end: int) -> list[dict]:
    """One metric for one app → the DO matrix `data.result` list ([] on error)."""
    try:
        body = do_get(
            f"v2/monitoring/metrics/apps/{endpoint}",
            {"app_id": app_id, "start": str(start), "end": str(end)},
        )
    except (urlerror.URLError, urlerror.HTTPError, ValueError) as exc:
        _log(f"  ⚠ {endpoint} for app {app_id}: {exc}")
        return []
    return (body.get("data", {}) or {}).get("result", []) or []


# ── Parse ────────────────────────────────────────────────────────────────────
def parse_series(metric_name: str, result: list[dict], app_name: str) -> list[dict]:
    """DO matrix result → one sample per series, taking the latest in-window point.

    Pure function — unit tested in test_do_metrics_bridge.py.
    """
    samples: list[dict] = []
    for series in result:
        values = series.get("values") or []
        if not values:
            continue
        _ts, raw = values[-1]
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        meta = series.get("metric", {}) or {}
        samples.append(
            {
                "metric": metric_name,
                "app": app_name,
                "component": meta.get("app_component", "?"),
                "instance": meta.get("app_component_instance", "?"),
                "value": value,
            }
        )
    return samples


# ── OTLP ─────────────────────────────────────────────────────────────────────
def _gauge(name: str, unit: str, points: list[dict]) -> dict:
    return {"name": name, "unit": unit, "gauge": {"dataPoints": points}}


def _point(value: float, now_ns: int, attrs: dict[str, str]) -> dict:
    return {
        "asDouble": float(value),
        "timeUnixNano": str(now_ns),
        "attributes": [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()],
    }


def build_otlp(samples: list[dict], env_label: str, now_ns: int) -> dict:
    """Group samples by metric name → OTLP gauges. Pure function (unit tested)."""
    by_metric: dict[str, list[dict]] = {}
    for s in samples:
        by_metric.setdefault(s["metric"], []).append(s)

    metrics = []
    for name, unit in APP_METRICS.values():
        points = [
            _point(
                s["value"],
                now_ns,
                {"app": s["app"], "component": s["component"], "instance": s["instance"], "env": env_label},
            )
            for s in by_metric.get(name, [])
        ]
        if points:
            metrics.append(_gauge(name, unit, points))

    return {
        "resourceMetrics": [
            {
                "resource": {
                    "attributes": [{"key": "service.name", "value": {"stringValue": "grove-do-metrics-bridge"}}]
                },
                "scopeMetrics": [{"scope": {"name": "grove.do_metrics", "version": "1"}, "metrics": metrics}],
            }
        ]
    }


def ship(payload: dict) -> None:
    url = _env("OPENOBSERVE_OTLP_METRICS_URL", "http://openobserve:5080/api/default/v1/metrics")
    email, password = _env("OPENOBSERVE_ROOT_EMAIL"), _env("OPENOBSERVE_ROOT_PASSWORD")
    headers = {"Content-Type": "application/json"}
    if email and password:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{email}:{password}".encode()).decode()
    req = request.Request(url, data=json.dumps(payload).encode(), method="POST", headers=headers)
    try:
        with request.urlopen(req, timeout=10) as resp:
            _log(f"  shipped app metrics → OpenObserve (HTTP {resp.status})")
    except urlerror.HTTPError as exc:
        _log(f"  ⚠ ship HTTP {exc.code}: {exc.read().decode()[:300]}")
    except urlerror.URLError as exc:
        _log(f"  ✗ ship network error: {exc.reason}")


def main() -> None:
    # Fail loud on the enable-but-misconfigured case: a silent no-op here would
    # leave the do_app_* streams empty and their alerts permanently silent, with
    # nothing in the logs to explain why.
    if _env("DO_METRICS_ENABLED", "false").strip().lower() != "true":
        _log("do-metrics bridge disabled (DO_METRICS_ENABLED!=true) — no-op")
        return
    if not _env("DO_API_TOKEN"):
        _log("✗ DO_METRICS_ENABLED=true but DO_API_TOKEN is unset — misconfigured; no app metrics produced")
        return
    env_label = _env("COST_ENV", "local")
    lookback = int(_env("DO_METRICS_LOOKBACK_SECONDS", "600") or "600")
    end = int(time.time())
    start = end - lookback
    _log(f"=== do-metrics bridge: env={env_label} window={lookback}s ===")

    try:
        apps = fetch_apps()
    except (urlerror.URLError, urlerror.HTTPError, ValueError, KeyError) as exc:
        _log(f"  ✗ DO API error listing apps: {exc}")
        return
    if not apps:
        _log("  no App Platform apps found — nothing to poll")
        return

    samples: list[dict] = []
    for app in apps:
        for endpoint, (metric_name, _unit) in APP_METRICS.items():
            result = fetch_app_metric(app["id"], endpoint, start, end)
            samples.extend(parse_series(metric_name, result, app["name"]))

    if not samples:
        _log(f"  {len(apps)} app(s) but no metric samples in-window — nothing shipped")
        return
    _log(f"  {len(samples)} sample(s) across {len(apps)} app(s)")
    ship(build_otlp(samples, env_label, time.time_ns()))


if __name__ == "__main__":
    main()
