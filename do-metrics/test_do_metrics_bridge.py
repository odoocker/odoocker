#!/usr/bin/env python3
"""Unit tests for the DO-metrics bridge's pure logic (no DO API / network).

Run: python3 do-metrics/test_do_metrics_bridge.py
"""

from __future__ import annotations

import sys

import do_metrics_bridge as bridge

# A realistic DO matrix `data.result` for one app component with two samples.
_MATRIX_RESULT = [
    {
        "metric": {
            "app_component": "web",
            "app_component_instance": "web-0",
            "app_uuid": "db3c021-15ad-4088",
        },
        "values": [
            [1634052360, "5.0166"],
            [1634052480, "42.75"],  # latest — this is the one we keep
        ],
    }
]


def test_parse_series_keeps_latest_point() -> None:
    samples = bridge.parse_series("do_app_cpu_percentage", _MATRIX_RESULT, "grove-hub")
    assert len(samples) == 1, samples
    s = samples[0]
    assert s["value"] == 42.75, s  # latest of the two, coerced to float
    assert s["app"] == "grove-hub"
    assert s["component"] == "web"
    assert s["instance"] == "web-0"
    assert s["metric"] == "do_app_cpu_percentage"


def test_parse_series_skips_empty_and_unparseable() -> None:
    result = [
        {"metric": {"app_component": "web"}, "values": []},  # no points
        {"metric": {"app_component": "web"}, "values": [[1, "not-a-number"]]},  # bad value
    ]
    assert bridge.parse_series("do_app_cpu_percentage", result, "app") == []


def test_build_otlp_groups_by_metric() -> None:
    samples = [
        {"metric": "do_app_cpu_percentage", "app": "hub", "component": "web", "instance": "web-0", "value": 42.75},
        {"metric": "do_app_memory_percentage", "app": "hub", "component": "web", "instance": "web-0", "value": 61.0},
        {"metric": "do_app_restart_count", "app": "hub", "component": "web", "instance": "web-0", "value": 0.0},
    ]
    payload = bridge.build_otlp(samples, "prod", now_ns=1_700_000_000_000_000_000)

    metrics = {m["name"]: m for m in payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]}
    assert set(metrics) == {"do_app_cpu_percentage", "do_app_memory_percentage", "do_app_restart_count"}, set(metrics)

    cpu = metrics["do_app_cpu_percentage"]["gauge"]["dataPoints"][0]
    assert cpu["asDouble"] == 42.75
    keys = {a["key"] for a in cpu["attributes"]}
    assert keys == {"app", "component", "instance", "env"}, keys
    assert {"key": "env", "value": {"stringValue": "prod"}} in cpu["attributes"]


def test_build_otlp_omits_metrics_with_no_samples() -> None:
    # only cpu samples → only the cpu gauge is emitted (no empty gauges)
    samples = [
        {"metric": "do_app_cpu_percentage", "app": "hub", "component": "web", "instance": "web-0", "value": 10.0},
    ]
    payload = bridge.build_otlp(samples, "local", now_ns=1)
    names = [m["name"] for m in payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]]
    assert names == ["do_app_cpu_percentage"], names


def test_disabled_without_token() -> None:
    import os

    saved = dict(os.environ)
    try:
        os.environ["DO_METRICS_ENABLED"] = "true"
        os.environ.pop("DO_API_TOKEN", None)
        assert bridge.is_enabled() is False
        os.environ["DO_API_TOKEN"] = "dop_v1_x"
        assert bridge.is_enabled() is True
        os.environ["DO_METRICS_ENABLED"] = "false"
        assert bridge.is_enabled() is False
    finally:
        os.environ.clear()
        os.environ.update(saved)


if __name__ == "__main__":
    test_parse_series_keeps_latest_point()
    test_parse_series_skips_empty_and_unparseable()
    test_build_otlp_groups_by_metric()
    test_build_otlp_omits_metrics_with_no_samples()
    test_disabled_without_token()
    print("ok: do-metrics bridge pure-logic tests", file=sys.stderr)
