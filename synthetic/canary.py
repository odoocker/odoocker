#!/usr/bin/env python3
"""
Synthetic checkout-canary support — Odoo XML-RPC side.

The checkout-canary journey (journeys/checkout-canary.hurl) exercises the money
path: it creates a $0 order via the bearer /orders endpoint and verifies the
access_token gate. This module owns the three XML-RPC operations that journey
can't do over the public HTTP API:

  seed     — upsert the shared $0 SYNTHETIC-CANARY product (company_id=False so
             it's visible to every tenant; website_published=False so it never
             shows in a storefront). Run by scripts/setup-monitoring.py.
  resolve  — find the canary product.product variant_id to order. Run by run.py
             once per cycle before the journeys.
  cleanup  — unlink the draft/sent sale.orders the canary created (matched by
             the .invalid partner email; never touches confirmed orders). Run by
             run.py after the journeys — self-healing, so it also sweeps any
             stragglers from an interrupted run.

OFF unless SYNTHETIC_CANARY_ENABLED=true AND ODOO_DB / ODOO_LOGIN /
SYNTHETIC_ODOO_API_KEY are set. The API key doubles as the HTTP bearer and the
XML-RPC password (Odoo accepts an API key as the XML-RPC password) — scope it to
a least-privilege user. Stdlib only (xmlrpc.client); all logs to stderr.

CLI: python3 canary.py --seed | --resolve | --cleanup
"""

from __future__ import annotations

import os
import sys
import xmlrpc.client

CANARY_CODE = "SYNTHETIC-CANARY"
CANARY_EMAIL = "synthetic-canary@grove.invalid"
CANARY_PRODUCT_NAME = "SYNTHETIC-CANARY (monitoring — do not sell)"


def _log(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def is_enabled() -> bool:
    return os.environ.get("SYNTHETIC_CANARY_ENABLED", "false").strip().lower() == "true"


def api_key() -> str:
    return os.environ.get("SYNTHETIC_ODOO_API_KEY", "")


def _config() -> dict | None:
    """Return XML-RPC config, or None (with a log) if anything required is missing."""
    cfg = {
        "url": os.environ.get("ODOO_XMLRPC_URL", "http://odoo:8069").rstrip("/"),
        "db": os.environ.get("ODOO_DB", ""),
        "login": os.environ.get("ODOO_LOGIN", ""),
        "key": api_key(),
    }
    missing = [k for k in ("db", "login", "key") if not cfg[k]]
    if missing:
        _log(f"  canary: missing env {missing} — XML-RPC ops skipped")
        return None
    return cfg


class _Client:
    """Thin authenticated Odoo XML-RPC client."""

    def __init__(self, cfg: dict):
        self.db = cfg["db"]
        self.key = cfg["key"]
        common = xmlrpc.client.ServerProxy(f"{cfg['url']}/xmlrpc/2/common")
        self.uid = common.authenticate(self.db, cfg["login"], self.key, {})
        if not self.uid:
            raise RuntimeError("Odoo XML-RPC authentication failed (check ODOO_DB/LOGIN/key)")
        self.models = xmlrpc.client.ServerProxy(f"{cfg['url']}/xmlrpc/2/object")

    def call(self, model: str, method: str, args: list, kwargs: dict | None = None):
        return self.models.execute_kw(self.db, self.uid, self.key, model, method, args, kwargs or {})


def _client() -> _Client | None:
    cfg = _config()
    if not cfg:
        return None
    try:
        return _Client(cfg)
    except (OSError, xmlrpc.client.Fault, RuntimeError) as exc:
        _log(f"  canary: XML-RPC connect failed: {exc}")
        return None


def seed() -> bool:
    """Upsert the shared $0, unpublished canary product. Idempotent by default_code."""
    cli = _client()
    if not cli:
        return False
    ids = cli.call("product.template", "search", [[["default_code", "=", CANARY_CODE]]], {"limit": 1})
    fields = {"list_price": 0.0, "sale_ok": True, "website_published": False}
    if ids:
        cli.call("product.template", "write", [ids, fields])
        _log(f"  canary: product up-to-date (template {ids[0]})")
    else:
        new_id = cli.call(
            "product.template",
            "create",
            [
                {
                    "name": CANARY_PRODUCT_NAME,
                    "default_code": CANARY_CODE,
                    "type": "service",
                    "company_id": False,
                    **fields,
                }
            ],
        )
        _log(f"  canary: product created (template {new_id})")
    return True


def resolve_variant_id() -> int | None:
    """Return the canary product.product variant id, or None."""
    cli = _client()
    if not cli:
        return None
    vids = cli.call("product.product", "search", [[["default_code", "=", CANARY_CODE]]], {"limit": 1})
    if not vids:
        _log("  canary: no variant found — seed first (setup-monitoring.py)")
        return None
    return vids[0]


def cleanup_orders() -> int:
    """Unlink draft/sent canary orders (matched by .invalid partner email). Returns count."""
    cli = _client()
    if not cli:
        return 0
    oids = cli.call(
        "sale.order",
        "search",
        [[["partner_id.email", "=", CANARY_EMAIL], ["state", "in", ["draft", "sent"]]]],
    )
    if oids:
        cli.call("sale.order", "unlink", [oids])
    return len(oids)


def main(argv: list[str]) -> int:
    if not is_enabled():
        _log("canary disabled (SYNTHETIC_CANARY_ENABLED!=true) — no-op")
        return 0
    action = argv[1] if len(argv) > 1 else "--seed"
    if action == "--seed":
        return 0 if seed() else 1
    if action == "--resolve":
        vid = resolve_variant_id()
        print(vid if vid is not None else "")
        return 0 if vid is not None else 1
    if action == "--cleanup":
        _log(f"canary: cleaned {cleanup_orders()} order(s)")
        return 0
    _log(f"unknown action {action!r}; use --seed | --resolve | --cleanup")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
