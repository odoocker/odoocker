#!/usr/bin/env python3
"""
Bootstrap the Grove monitoring stack — OpenObserve + Keep.

Reads the canonical configs in:
    odoocker/openobserve/monitors.json
    odoocker/openobserve/alerts.json
    odoocker/openobserve/dashboards.json
    odoocker/keep/providers.yml
    odoocker/keep/workflows.yml

POSTs each to the running OpenObserve / Keep REST API. Idempotent: re-runs
upsert by 'name' / 'id', so this can run on every `make monitoring-up`
without creating duplicates.

Secrets substituted from .env.monitoring at runtime:
    DISCORD_WEBHOOK_WARNING  -> Keep providers.discord-warning.webhook_url
    DISCORD_WEBHOOK_CRITICAL -> Keep providers.discord-critical.webhook_url
    KEEP_WEBHOOK_TOKEN       -> OpenObserve alert destinations URL
    OPENOBSERVE_ROOT_*       -> bearer auth on OpenObserve API
    MINIO_ROOT_*             -> OpenObserve storage backend (already in compose env)

Mirrors the shape of scripts/setup_ghost_integration.py — see that file
for the canonical pattern for idempotent service bootstraps in odoocker.

Usage:
    GHOST_WEBHOOK_TOKEN=... ./scripts/setup-monitoring.py
    # or just:
    make monitoring-setup   # reads env from .env.monitoring automatically
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error as urlerror
from urllib import request

# ── paths (resolved from this script's location, not CWD) ─────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
OPENOBSERVE_DIR = REPO_ROOT / "openobserve"
KEEP_DIR = REPO_ROOT / "keep"
SYNTHETIC_DIR = REPO_ROOT / "synthetic"


def maybe_seed_canary() -> None:
    """Seed the synthetic checkout-canary product (opt-in).

    Delegates to synthetic/canary.py --seed (the single owner of the canary
    XML-RPC logic). No-op unless SYNTHETIC_CANARY_ENABLED=true. Run before
    monitors so the canary journey never fires without its product.
    """
    if get_env("SYNTHETIC_CANARY_ENABLED", "false").strip().lower() != "true":
        _log("  checkout-canary disabled (SYNTHETIC_CANARY_ENABLED!=true) — skipping seed")
        return
    canary = SYNTHETIC_DIR / "canary.py"
    rc = subprocess.run([sys.executable, str(canary), "--seed"], check=False).returncode
    _log("  ✓ canary product seeded" if rc == 0 else f"  ⚠ canary seed failed (rc={rc})")


def _log(*args: Any) -> None:
    """All output to stderr so callers can pipe stdout if needed."""
    print(*args, file=sys.stderr, flush=True)


# ── env helpers ──────────────────────────────────────────────────────────────
def require_env(name: str) -> str:
    """Read an env var or exit with a helpful error."""
    val = os.environ.get(name)
    if not val:
        _log(f"ERROR: required env var {name} is not set.")
        _log("  Source it from .env.monitoring or export it before running.")
        sys.exit(1)
    return val


def get_env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


# ── HTTP wrapper ─────────────────────────────────────────────────────────────
def http_request(
    method: str,
    url: str,
    *,
    body: dict | None = None,
    auth: tuple[str, str] | None = None,
    bearer: str | None = None,
    timeout: float = 15.0,
) -> tuple[int, dict | str]:
    """
    Minimal HTTP client using stdlib (avoids adding a dependency).
    Returns (status_code, parsed_body_or_text).
    """
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    if auth:
        import base64

        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = request.Request(url, data=data, method=method, headers=headers)
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urlerror.HTTPError as e:
        raw = e.read().decode() if e.fp else ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except urlerror.URLError as e:
        _log(f"  network error: {e.reason}")
        return 0, str(e.reason)


def wait_for(url: str, max_wait_s: int, *, name: str) -> None:
    """Block until url returns any HTTP code other than 0 (connection error)."""
    _log(f"  waiting for {name} at {url} (up to {max_wait_s}s)...")
    deadline = time.time() + max_wait_s
    while time.time() < deadline:
        code, _ = http_request("GET", url, timeout=3)
        if code != 0:
            _log(f"  {name} responding (HTTP {code})")
            return
        time.sleep(2)
    _log(f"  ERROR: {name} never responded within {max_wait_s}s")
    sys.exit(1)


# ── OpenObserve API ──────────────────────────────────────────────────────────
def oo_base_url() -> str:
    # If OPENOBSERVE_BASE_URL is set (e.g. running against a remote obs droplet
    # in CI per ADR-007 addendum's Phase 1.5), use it verbatim and only append
    # /api/default. Otherwise fall back to localhost:OPENOBSERVE_PORT for local
    # `make monitoring-up` usage where this script + OpenObserve run side-by-side.
    base = get_env("OPENOBSERVE_BASE_URL", "")
    if base:
        return f"{base.rstrip('/')}/api/default"
    port = get_env("OPENOBSERVE_PORT", "5080")
    return f"http://localhost:{port}/api/default"


def oo_auth() -> tuple[str, str]:
    return require_env("OPENOBSERVE_ROOT_EMAIL"), require_env("OPENOBSERVE_ROOT_PASSWORD")


def oo_bootstrap_monitors() -> None:
    src = OPENOBSERVE_DIR / "monitors.json"
    data = json.loads(src.read_text())
    monitors = [m for m in data.get("monitors", []) if not m.get("_comment")]
    _log(f"  uploading {len(monitors)} synthetic monitors...")
    for m in monitors:
        # Strip our _note / _comment fields — OO will reject unknown keys
        payload = {k: v for k, v in m.items() if not k.startswith("_")}
        code, _resp = http_request(
            "POST",
            f"{oo_base_url()}/synthetic",
            body=payload,
            auth=oo_auth(),
        )
        if code in (200, 201):
            _log(f"    ✓ {m['name']}")
        elif code == 409:
            # Already exists — try update
            code2, _ = http_request(
                "PUT",
                f"{oo_base_url()}/synthetic/{m['name']}",
                body=payload,
                auth=oo_auth(),
            )
            status = "✓ updated" if code2 in (200, 204) else f"⚠ {code2}"
            _log(f"    {status} {m['name']}")
        else:
            _log(f"    ✗ {m['name']} — HTTP {code}")


def oo_bootstrap_alerts() -> None:
    src = OPENOBSERVE_DIR / "alerts.json"
    data = json.loads(src.read_text())
    alerts = [a for a in data.get("alerts", []) if not a.get("_comment")]
    keep_token = require_env("KEEP_WEBHOOK_TOKEN")
    _log(f"  uploading {len(alerts)} alert rules...")
    for a in alerts:
        payload = {k: v for k, v in a.items() if not k.startswith("_")}
        # Substitute the Keep webhook token into the destination URL.
        # OpenObserve's destinations are separate API objects; for simplicity
        # here we inline the URL into the alert config.
        payload["destination_url"] = f"http://keep-backend:8080/alerts/event/{keep_token}"
        code, _ = http_request(
            "POST",
            f"{oo_base_url()}/alerts",
            body=payload,
            auth=oo_auth(),
        )
        if code in (200, 201):
            _log(f"    ✓ {a['name']}")
        elif code == 409:
            code2, _ = http_request(
                "PUT",
                f"{oo_base_url()}/alerts/{a['name']}",
                body=payload,
                auth=oo_auth(),
            )
            status = "✓ updated" if code2 in (200, 204) else f"⚠ {code2}"
            _log(f"    {status} {a['name']}")
        else:
            _log(f"    ✗ {a['name']} — HTTP {code}")


def oo_bootstrap_dashboards() -> None:
    src = OPENOBSERVE_DIR / "dashboards.json"
    data = json.loads(src.read_text())
    dashboards = [d for d in data.get("dashboards", []) if not d.get("_comment")]
    _log(f"  uploading {len(dashboards)} dashboards...")
    for d in dashboards:
        payload = {k: v for k, v in d.items() if not k.startswith("_")}
        code, _ = http_request(
            "POST",
            f"{oo_base_url()}/dashboards",
            body=payload,
            auth=oo_auth(),
        )
        status = "✓" if code in (200, 201, 409) else f"✗ HTTP {code}"
        _log(f"    {status} {d['name']}")


# ── Keep API ─────────────────────────────────────────────────────────────────
def keep_base_url() -> str:
    # If KEEP_BASE_URL is set (remote obs droplet path), use it verbatim and
    # append /api/v1. Otherwise fall back to localhost:KEEP_BACKEND_PORT for
    # local docker-compose.monitoring.yml usage.
    base = get_env("KEEP_BASE_URL", "")
    if base:
        return f"{base.rstrip('/')}/api/v1"
    port = get_env("KEEP_BACKEND_PORT", "8080")
    return f"http://localhost:{port}/api/v1"


def keep_bootstrap_providers() -> None:
    """Discord webhooks substituted from env, providers POSTed to Keep."""
    # yaml in stdlib? no. tiny parser inline to avoid a PyYAML dep on operators.
    import re

    src = KEEP_DIR / "providers.yml"
    raw = src.read_text()

    warning_url = require_env("DISCORD_WEBHOOK_WARNING")
    critical_url = require_env("DISCORD_WEBHOOK_CRITICAL")
    raw = raw.replace("{DISCORD_WEBHOOK_WARNING}", warning_url)
    raw = raw.replace("{DISCORD_WEBHOOK_CRITICAL}", critical_url)

    # Minimal YAML→dict parser: extract each provider's id, type, name, config.webhook_url
    # Real impl would use PyYAML; this avoids the dependency for operators.
    providers: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in raw.splitlines():
        m = re.match(r"^\s*- id:\s+(\S+)", line)
        if m:
            if current:
                providers.append(current)
            current = {"id": m.group(1)}
            continue
        if current is None:
            continue
        m = re.match(r"^\s+type:\s+(\S+)", line)
        if m:
            current["type"] = m.group(1)
        m = re.match(r"^\s+name:\s+\"(.+)\"", line)
        if m:
            current["name"] = m.group(1)
        m = re.match(r"^\s+webhook_url:\s+\"(.+)\"", line)
        if m:
            current.setdefault("config", {})["webhook_url"] = m.group(1)
    if current:
        providers.append(current)

    _log(f"  uploading {len(providers)} Keep providers...")
    for p in providers:
        code, _ = http_request(
            "POST",
            f"{keep_base_url()}/providers/install",
            body={
                "provider_id": p["id"],
                "provider_type": p["type"],
                "provider_name": p.get("name", p["id"]),
                "provider_config": p.get("config", {}),
            },
        )
        status = "✓" if code in (200, 201, 409) else f"✗ HTTP {code}"
        _log(f"    {status} {p['id']}")


def keep_bootstrap_workflows() -> None:
    """Workflow YAML uploaded as-is to Keep (Keep parses YAML natively)."""
    src = KEEP_DIR / "workflows.yml"
    raw = src.read_text()
    # Keep's workflow endpoint accepts a YAML body
    _log("  uploading workflows.yml to Keep...")
    headers = {"Content-Type": "application/x-yaml"}
    req = request.Request(
        f"{keep_base_url()}/workflows",
        data=raw.encode(),
        method="POST",
        headers=headers,
    )
    try:
        with request.urlopen(req, timeout=15) as resp:
            _log(f"    ✓ workflows uploaded (HTTP {resp.status})")
    except urlerror.HTTPError as e:
        _log(f"    ⚠ HTTP {e.code} — {e.read().decode()[:200]}")
    except urlerror.URLError as e:
        _log(f"    ✗ network error: {e.reason}")


# ── main ─────────────────────────────────────────────────────────────────────
def main() -> None:
    _log("=== Grove monitoring bootstrap ===")
    _log("")

    _log("Step 1/5: wait for OpenObserve")
    wait_for(f"{oo_base_url().rsplit('/api/', 1)[0]}/healthz", 90, name="OpenObserve")

    _log("\nStep 2/5: wait for Keep backend")
    wait_for(f"{keep_base_url().rsplit('/api/', 1)[0]}/healthcheck", 120, name="Keep")

    _log("\nStep 3/5: bootstrap OpenObserve")
    maybe_seed_canary()
    oo_bootstrap_monitors()
    oo_bootstrap_alerts()
    oo_bootstrap_dashboards()

    _log("\nStep 4/5: bootstrap Keep")
    keep_bootstrap_providers()
    keep_bootstrap_workflows()

    _log("\nStep 5/5: summary")
    _log("=" * 50)
    _log(f"  OpenObserve UI:  http://localhost:{get_env('OPENOBSERVE_PORT', '5080')}")
    _log(f"  Keep UI:         http://localhost:{get_env('KEEP_PORT', '3034')}")
    _log("")
    _log("Verify Discord wiring:")
    _log("  curl -X POST http://localhost:8080/alerts/event/$KEEP_WEBHOOK_TOKEN \\")
    _log("    -H 'Content-Type: application/json' \\")
    _log('    -d \'{"name":"test","severity":"warning","message":"connectivity check"}\'')
    _log("  → should appear in your Discord warning channel within 5s")
    _log("")
    _log("Run end-to-end kill-test:")
    _log("  ./scripts/smoke-test-monitoring.sh")


if __name__ == "__main__":
    main()
