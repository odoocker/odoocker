#!/usr/bin/env python3
"""Unit tests for the cost bridge's pure logic (no DO API / network).

Run: python3 cost/test_do_billing_bridge.py
"""

from __future__ import annotations

import sys

import do_billing_bridge as bridge


def test_build_otlp_shape() -> None:
    account = {"month_to_date": 42.5, "balance": -10.0, "month_to_date_usage": 42.5}
    resources = [
        {"type": "droplet", "name": "obs", "size": "s-1vcpu-2gb", "monthly": 12.0},
        {"type": "app", "name": "grove-hub", "size": "app-platform", "monthly": 5.0},
    ]
    payload = bridge.build_otlp(account, resources, "prod", now_ns=1_700_000_000_000_000_000)

    metrics = {m["name"]: m for m in payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]}
    assert set(metrics) == {
        "cost_account_month_to_date",
        "cost_account_balance",
        "cost_account_month_to_date_usage",
        "cost_resource_monthly_estimate",
    }, set(metrics)

    # account gauges carry the value + env
    mtd = metrics["cost_account_month_to_date"]["gauge"]["dataPoints"][0]
    assert mtd["asDouble"] == 42.5
    assert {"key": "env", "value": {"stringValue": "prod"}} in mtd["attributes"]

    # per-resource gauge has one point per resource, tagged type/name/size/env
    points = metrics["cost_resource_monthly_estimate"]["gauge"]["dataPoints"]
    assert len(points) == 2, len(points)
    keys = {a["key"] for a in points[0]["attributes"]}
    assert keys == {"type", "name", "size", "env"}, keys


def test_unknown_slug_prices_zero() -> None:
    # unknown droplet slug → 0.0 (and would log), never a crash / wrong number
    assert bridge._price(bridge.DROPLET_PRICES, "s-99vcpu-nonsense", "droplet") == 0.0
    assert bridge._price(bridge.DROPLET_PRICES, "s-2vcpu-4gb", "droplet") == 24.0


def test_disabled_without_token(monkeypatch_env: dict | None = None) -> None:
    # is_enabled() is false unless both the flag AND a token are present
    import os

    saved = dict(os.environ)
    try:
        os.environ["COST_BRIDGE_ENABLED"] = "true"
        os.environ.pop("DO_API_TOKEN", None)
        assert bridge.is_enabled() is False
        os.environ["DO_API_TOKEN"] = "dop_v1_x"
        assert bridge.is_enabled() is True
    finally:
        os.environ.clear()
        os.environ.update(saved)


if __name__ == "__main__":
    test_build_otlp_shape()
    test_unknown_slug_prices_zero()
    test_disabled_without_token()
    print("ok: cost bridge pure-logic tests", file=sys.stderr)
