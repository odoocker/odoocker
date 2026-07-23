#!/usr/bin/env python3
"""
Grove synthetic Tier-1 runner.

Runs the Hurl journeys in ./journeys against the live Odoo grove_headless API,
once per tenant (plus the shared health journey), then ships the results to
OpenObserve as OTLP metrics:

    synthetic_journey_success      gauge 1/0   {journey, tenant, tier, env}
    synthetic_journey_duration_ms  gauge ms    {journey, tenant, tier, env}

Invoked every minute by supercronic (see ./crontab). Pass/fail is the Hurl
`--test` exit code; duration is the wall-clock of the Hurl run (good enough for
latency alerting at this tier). The process always exits 0 — failures are
reported as metrics, not as a crashed cron job (which supercronic would only
surface in logs).

Mirrors scripts/setup-monitoring.py: stdlib only, all logs to stderr.

Env contract (see .env.monitoring.example):
    SYNTHETIC_ODOO_BASE            default http://odoo:8069
    SYNTHETIC_TENANTS             default goldberry,ggg,nursery
    SYNTHETIC_ENV                 default local   (env label on every metric)
    OPENOBSERVE_OTLP_METRICS_URL  default http://openobserve:5080/api/default/v1/metrics
    OPENOBSERVE_ROOT_EMAIL        basic-auth user for OpenObserve ingest
    OPENOBSERVE_ROOT_PASSWORD     basic-auth pass
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib import error as urlerror
from urllib import request

import canary

SCRIPT_DIR = Path(__file__).resolve().parent
JOURNEY_DIR = SCRIPT_DIR / "journeys"

# Per-tenant journeys (run once for each tenant) and shared journeys (run once,
# tagged tenant="shared"). Keep names stable — alert rules query them by value.
TENANT_JOURNEYS = [("catalog", "catalog.hurl"), ("cart-flow", "cart-flow.hurl")]
SHARED_JOURNEYS = [("health", "health.hurl")]

CONNECT_TIMEOUT_S = "5"
MAX_TIME_S = "20"


def _log(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def ghost_vars_for(tenant: str) -> dict | None:
    """Per-tenant Ghost Content API url+key from env, or None if not configured.

    Opt-in: SYNTHETIC_GHOST_ENABLED=true + GHOST_URL_<TENANT> / GHOST_KEY_<TENANT>
    (e.g. GHOST_URL_GOLDBERRY). The content key is passed to Hurl via a
    variables-file (out of argv).
    """
    if _env("SYNTHETIC_GHOST_ENABLED", "false").strip().lower() != "true":
        return None
    t = tenant.upper()
    url, key = _env(f"GHOST_URL_{t}"), _env(f"GHOST_KEY_{t}")
    return {"ghost_url": url, "ghost_key": key} if url and key else None


def run_journey(journey_file: str, *, tenant: str, odoo_base: str, extra_vars: dict | None = None) -> tuple[int, float]:
    """Run one Hurl journey. Returns (success 1/0, duration_ms).

    extra_vars (e.g. the canary's variant_id + api_key) are passed via a
    temp variables-file rather than --variable so secrets stay out of argv.
    """
    path = JOURNEY_DIR / journey_file
    cmd = [
        "hurl",
        "--test",
        "--connect-timeout",
        CONNECT_TIMEOUT_S,
        "--max-time",
        MAX_TIME_S,
        "--variable",
        f"odoo_base={odoo_base}",
        "--variable",
        f"tenant={tenant}",
    ]
    varfile_path = None
    if extra_vars:
        with tempfile.NamedTemporaryFile("w", suffix=".vars", delete=False) as varfile:
            varfile.writelines(f"{k}={v}\n" for k, v in extra_vars.items())
            varfile_path = varfile.name
        cmd += ["--variables-file", varfile_path]
    cmd.append(str(path))

    start = time.perf_counter()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=float(MAX_TIME_S) + 10)
        rc = proc.returncode
        if rc != 0:
            _log(f"    ✗ {journey_file} [{tenant}] rc={rc}\n{proc.stderr.strip()[:500]}")
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        rc = 1
        _log(f"    ✗ {journey_file} [{tenant}] runner error: {exc}")
    finally:
        if varfile_path:
            os.unlink(varfile_path)
    duration_ms = (time.perf_counter() - start) * 1000.0
    return (1 if rc == 0 else 0), duration_ms


def build_otlp_metrics(results: list[dict], now_ns: int, env_label: str) -> dict:
    """Build an OTLP/HTTP JSON metrics payload from journey results.

    `results` is a list of {journey, tenant, success, duration_ms}. Emits two
    gauges sharing the same attribute set per data point. Pure function — unit
    tested in test_run.py.
    """
    success_points = []
    duration_points = []
    for r in results:
        attrs = [
            {"key": "journey", "value": {"stringValue": r["journey"]}},
            {"key": "tenant", "value": {"stringValue": r["tenant"]}},
            {"key": "tier", "value": {"stringValue": "api"}},
            {"key": "env", "value": {"stringValue": env_label}},
        ]
        success_points.append({"asInt": str(int(r["success"])), "timeUnixNano": str(now_ns), "attributes": attrs})
        duration_points.append({"asDouble": float(r["duration_ms"]), "timeUnixNano": str(now_ns), "attributes": attrs})
    return {
        "resourceMetrics": [
            {
                "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "grove-synthetic"}}]},
                "scopeMetrics": [
                    {
                        "scope": {"name": "grove.synthetic", "version": "1"},
                        "metrics": [
                            {
                                "name": "synthetic_journey_success",
                                "unit": "1",
                                "gauge": {"dataPoints": success_points},
                            },
                            {
                                "name": "synthetic_journey_duration_ms",
                                "unit": "ms",
                                "gauge": {"dataPoints": duration_points},
                            },
                        ],
                    }
                ],
            }
        ]
    }


def ship(payload: dict) -> None:
    url = _env(
        "OPENOBSERVE_OTLP_METRICS_URL",
        "http://openobserve:5080/api/default/v1/metrics",
    )
    email = _env("OPENOBSERVE_ROOT_EMAIL")
    password = _env("OPENOBSERVE_ROOT_PASSWORD")
    headers = {"Content-Type": "application/json"}
    if email and password:
        token = base64.b64encode(f"{email}:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"
    points = payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["gauge"]["dataPoints"]
    req = request.Request(url, data=json.dumps(payload).encode(), method="POST", headers=headers)
    try:
        with request.urlopen(req, timeout=10) as resp:
            _log(f"  shipped {len(points)} results → OpenObserve (HTTP {resp.status})")
    except urlerror.HTTPError as exc:
        _log(f"  ⚠ ship HTTP {exc.code}: {exc.read().decode()[:300]}")
    except urlerror.URLError as exc:
        _log(f"  ✗ ship network error: {exc.reason}")


def main() -> None:
    odoo_base = _env("SYNTHETIC_ODOO_BASE", "http://odoo:8069")
    tenants = [t.strip() for t in _env("SYNTHETIC_TENANTS", "goldberry,ggg,nursery").split(",") if t.strip()]
    env_label = _env("SYNTHETIC_ENV", "local")
    _log(f"=== synthetic run: tenants={tenants} odoo={odoo_base} env={env_label} ===")

    # checkout-canary is opt-in (needs an Odoo API key) and adds the money-path
    # write/auth journey. Resolve the shared canary variant once up front; if it
    # can't be resolved, run the read/cart journeys only.
    canary_vars = None
    if canary.is_enabled():
        variant_id = canary.resolve_variant_id()
        if variant_id is not None:
            canary_vars = {"variant_id": str(variant_id), "api_key": canary.api_key()}
        else:
            _log("  checkout-canary enabled but variant unresolved — skipping it this run")

    results: list[dict] = []
    for journey_name, journey_file in SHARED_JOURNEYS:
        success, dur = run_journey(journey_file, tenant="shared", odoo_base=odoo_base)
        results.append({"journey": journey_name, "tenant": "shared", "success": success, "duration_ms": dur})
    for tenant in tenants:
        for journey_name, journey_file in TENANT_JOURNEYS:
            success, dur = run_journey(journey_file, tenant=tenant, odoo_base=odoo_base)
            results.append({"journey": journey_name, "tenant": tenant, "success": success, "duration_ms": dur})
        gvars = ghost_vars_for(tenant)
        if gvars is not None:
            success, dur = run_journey("ghost-content.hurl", tenant=tenant, odoo_base=odoo_base, extra_vars=gvars)
            results.append({"journey": "ghost-content", "tenant": tenant, "success": success, "duration_ms": dur})
        if canary_vars is not None:
            success, dur = run_journey(
                "checkout-canary.hurl", tenant=tenant, odoo_base=odoo_base, extra_vars=canary_vars
            )
            results.append({"journey": "checkout-canary", "tenant": tenant, "success": success, "duration_ms": dur})

    # Sweep the draft orders the canary created (self-healing: also clears
    # stragglers from any interrupted run).
    if canary_vars is not None:
        _log(f"  canary cleanup: removed {canary.cleanup_orders()} draft order(s)")

    passed = sum(r["success"] for r in results)
    _log(f"  {passed}/{len(results)} journeys passed")
    ship(build_otlp_metrics(results, time.time_ns(), env_label))


if __name__ == "__main__":
    main()
