#!/usr/bin/env python3
"""
Grove CostOps — DigitalOcean billing bridge → OpenObserve.

Polls the DigitalOcean API and ships cost as OTLP metrics so "what we spend and
what to trim" lives in the same OpenObserve pane as the USE/utilization metrics
(spec docs/specs/2026-06-26-grove-observability-design.md §6).

Two kinds of signal:
  cost_account_*              the ACTUAL aggregate truth, straight from
                             GET /v2/customers/my/balance (no pricing guesswork)
  cost_resource_monthly_estimate   per-resource DERIVED cost = live inventory
                             (droplets/apps/dbs/volumes) × a static DO price
                             list. DO billing is invoice-grained, not
                             per-resource-itemized, so this is an estimate
                             (the same approach Infracost uses) — good enough
                             for rightsizing + budget alerting.

Joined with USE metrics in OpenObserve, cost_resource_* × low-utilization is the
"what to trim" dashboard.

OFF unless COST_BRIDGE_ENABLED=true AND DO_API_TOKEN is set. Scheduled hourly by
supercronic (see ./crontab). Stdlib only; all logs to stderr; always exits 0.

Env (see .env.monitoring.example):
    COST_BRIDGE_ENABLED           default false
    DO_API_TOKEN                  read-only DigitalOcean API token
    COST_ENV                      default local   (env label on every metric)
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
from urllib import request

DO_API_BASE = "https://api.digitalocean.com"

# ── Static DO price list (USD / month) ───────────────────────────────────────
# DO published list prices. UPDATE when DO changes pricing or a new size is used
# — unknown slugs price to 0.0 and are logged, so drift is visible not silent.
DROPLET_PRICES = {
    "s-1vcpu-1gb": 6.0,
    "s-1vcpu-2gb": 12.0,
    "s-2vcpu-2gb": 18.0,
    "s-2vcpu-4gb": 24.0,
    "s-4vcpu-8gb": 48.0,
}
APP_INSTANCE_PRICES = {
    "apps-s-1vcpu-0.5gb": 5.0,
    "apps-s-1vcpu-1gb": 12.0,
    "apps-s-1vcpu-2gb": 25.0,
    "apps-s-2vcpu-4gb": 50.0,
}
DB_PRICES = {
    "db-s-1vcpu-1gb": 15.0,
    "db-s-1vcpu-2gb": 30.0,
    "db-s-2vcpu-4gb": 60.0,
}
VOLUME_PRICE_PER_GB = 0.10


def _log(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def is_enabled() -> bool:
    return _env("COST_BRIDGE_ENABLED", "false").strip().lower() == "true" and bool(_env("DO_API_TOKEN"))


def _price(table: dict[str, float], slug: str, kind: str) -> float:
    if slug not in table:
        _log(f"  cost: unknown {kind} size '{slug}' — priced 0.0 (update the price table)")
    return table.get(slug, 0.0)


# ── DO API ───────────────────────────────────────────────────────────────────
def do_get(path: str) -> dict:
    url = f"{DO_API_BASE}/{path.lstrip('/')}"
    req = request.Request(url, headers={"Authorization": f"Bearer {_env('DO_API_TOKEN')}"})
    with request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def fetch_account() -> dict[str, float]:
    """The actual aggregate truth (dollar strings → floats)."""
    b = do_get("v2/customers/my/balance")
    return {
        "month_to_date": float(b.get("month_to_date_balance", 0) or 0),
        "balance": float(b.get("account_balance", 0) or 0),
        "month_to_date_usage": float(b.get("month_to_date_usage", 0) or 0),
    }


def fetch_resources() -> list[dict]:
    """Live inventory × price list → per-resource monthly estimate."""
    out: list[dict] = []

    for d in do_get("v2/droplets?per_page=200").get("droplets", []):
        slug = d.get("size_slug", "")
        out.append(
            {
                "type": "droplet",
                "name": d.get("name", "?"),
                "size": slug,
                "monthly": _price(DROPLET_PRICES, slug, "droplet"),
            }
        )

    for db in do_get("v2/databases?per_page=200").get("databases", []):
        slug = db.get("size", "")
        nodes = int(db.get("num_nodes", 1) or 1)
        out.append(
            {
                "type": "database",
                "name": db.get("name", "?"),
                "size": slug,
                "monthly": _price(DB_PRICES, slug, "database") * nodes,
            }
        )

    for app in do_get("v2/apps?per_page=200").get("apps", []):
        spec = app.get("spec", {}) or {}
        monthly = 0.0
        for svc in spec.get("services", []) or []:
            slug = svc.get("instance_size_slug", "")
            count = int(svc.get("instance_count", 1) or 1)
            monthly += _price(APP_INSTANCE_PRICES, slug, "app") * count
        out.append({"type": "app", "name": spec.get("name", "?"), "size": "app-platform", "monthly": monthly})

    for v in do_get("v2/volumes?per_page=200").get("volumes", []):
        gb = float(v.get("size_gigabytes", 0) or 0)
        out.append(
            {
                "type": "volume",
                "name": v.get("name", "?"),
                "size": f"{gb:g}GB",
                "monthly": round(gb * VOLUME_PRICE_PER_GB, 2),
            }
        )

    return out


# ── OTLP ─────────────────────────────────────────────────────────────────────
def _gauge(name: str, unit: str, points: list[dict]) -> dict:
    return {"name": name, "unit": unit, "gauge": {"dataPoints": points}}


def _point(value: float, now_ns: int, attrs: dict[str, str]) -> dict:
    return {
        "asDouble": float(value),
        "timeUnixNano": str(now_ns),
        "attributes": [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()],
    }


def build_otlp(account: dict[str, float], resources: list[dict], env_label: str, now_ns: int) -> dict:
    """Pure function — unit tested in test_do_billing_bridge.py."""
    env_attrs = {"env": env_label}
    metrics = [
        _gauge("cost_account_month_to_date", "USD", [_point(account["month_to_date"], now_ns, env_attrs)]),
        _gauge("cost_account_balance", "USD", [_point(account["balance"], now_ns, env_attrs)]),
        _gauge("cost_account_month_to_date_usage", "USD", [_point(account["month_to_date_usage"], now_ns, env_attrs)]),
        _gauge(
            "cost_resource_monthly_estimate",
            "USD",
            [
                _point(r["monthly"], now_ns, {"type": r["type"], "name": r["name"], "size": r["size"], **env_attrs})
                for r in resources
            ],
        ),
    ]
    return {
        "resourceMetrics": [
            {
                "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "grove-cost-bridge"}}]},
                "scopeMetrics": [{"scope": {"name": "grove.cost", "version": "1"}, "metrics": metrics}],
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
            _log(f"  shipped cost metrics → OpenObserve (HTTP {resp.status})")
    except urlerror.HTTPError as exc:
        _log(f"  ⚠ ship HTTP {exc.code}: {exc.read().decode()[:300]}")
    except urlerror.URLError as exc:
        _log(f"  ✗ ship network error: {exc.reason}")


def main() -> None:
    # Fail loud on the enable-but-misconfigured case: a silent no-op here would
    # leave the cost_* streams empty and their alerts permanently silent, with
    # nothing in the logs to explain why.
    if _env("COST_BRIDGE_ENABLED", "false").strip().lower() != "true":
        _log("cost bridge disabled (COST_BRIDGE_ENABLED!=true) — no-op")
        return
    if not _env("DO_API_TOKEN"):
        _log("✗ COST_BRIDGE_ENABLED=true but DO_API_TOKEN is unset — misconfigured; no cost metrics produced")
        return
    env_label = _env("COST_ENV", "local")
    _log(f"=== cost bridge: env={env_label} ===")
    try:
        account = fetch_account()
        resources = fetch_resources()
    except (urlerror.URLError, urlerror.HTTPError, ValueError, KeyError) as exc:
        _log(f"  ✗ DO API error: {exc}")
        return
    total_est = sum(r["monthly"] for r in resources)
    _log(f"  MTD=${account['month_to_date']:.2f}  est. inventory=${total_est:.2f}/mo across {len(resources)} resources")
    ship(build_otlp(account, resources, env_label, time.time_ns()))


if __name__ == "__main__":
    main()
