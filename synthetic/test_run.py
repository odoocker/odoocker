#!/usr/bin/env python3
"""Unit tests for the synthetic runner's OTLP metric builder.

Runs without Hurl, OpenObserve, or a network — verifies the one piece of pure
logic locally:  python3 synthetic/test_run.py
"""

from __future__ import annotations

import sys

import run


def test_otlp_shape() -> None:
    results = [
        {"journey": "health", "tenant": "shared", "success": 1, "duration_ms": 12.5},
        {"journey": "cart-flow", "tenant": "goldberry", "success": 0, "duration_ms": 2003.1},
    ]
    payload = run.build_otlp_metrics(results, now_ns=1_700_000_000_000_000_000, env_label="local")

    metrics = payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]
    names = {m["name"] for m in metrics}
    assert names == {"synthetic_journey_success", "synthetic_journey_duration_ms"}, names

    success = next(m for m in metrics if m["name"] == "synthetic_journey_success")
    points = success["gauge"]["dataPoints"]
    assert len(points) == 2, len(points)
    # success is an int gauge expressed as a string per OTLP/HTTP JSON
    assert points[0]["asInt"] == "1" and points[1]["asInt"] == "0"

    duration = next(m for m in metrics if m["name"] == "synthetic_journey_duration_ms")
    dpoints = duration["gauge"]["dataPoints"]
    assert dpoints[0]["asDouble"] == 12.5

    # every data point carries the four expected attributes
    attr_keys = {a["key"] for a in points[0]["attributes"]}
    assert attr_keys == {"journey", "tenant", "tier", "env"}, attr_keys
    tier = next(a for a in points[0]["attributes"] if a["key"] == "tier")
    assert tier["value"]["stringValue"] == "api"


def test_empty_results() -> None:
    payload = run.build_otlp_metrics([], now_ns=1, env_label="local")
    metrics = payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]
    assert all(m["gauge"]["dataPoints"] == [] for m in metrics)


if __name__ == "__main__":
    test_otlp_shape()
    test_empty_results()
    print("ok: synthetic runner OTLP builder", file=sys.stderr)
