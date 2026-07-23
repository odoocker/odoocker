#!/usr/bin/env python3
"""
Grove logistics Odoo client — a least-privilege XML-RPC entry point for the
Logistics & Inventory Specialist agent (Otto).

Talks to the self-hosted Odoo external API (https://www.odoo.com/documentation
/19.0/developer/reference/external_api.html) using nothing but the Python
standard library (`xmlrpc.client`), matching the odoocker house style
(stdlib-only, all logs to stderr).

SECURITY MODEL
--------------
- Credentials are read ONLY from the environment. Nothing is hard-coded and
  nothing is written back to disk. See the env contract below.
- Model allow-lists gate every call. Reads are restricted to the
  inventory / purchase / sales / reconciliation models a logistics specialist
  needs; writes are restricted to the subset that is actually his job to edit.
- Destructive operations are gated:
    * `unlink` (delete) is refused for every model.
    * `create` / `write` require an explicit `--confirm` flag and are logged
      to stderr with the full payload before they run.
    * Money/finance/CRM models (account.*, payment.*, sale.order, res.partner)
      are read-only through this tool, even though they are readable for
      reconciliation.
    * Field-level gate: even on writable models, governance-gated fields are
      refused. Confirming a purchase order (writing `purchase.order.state`)
      commits binding spend and is CFO-only — drafts only through this tool.
- The Odoo user itself should also be least-privilege (Inventory + Purchase +
  Sales groups only, NOT admin). This tool is defense-in-depth on top of that,
  not a substitute for it. See scripts/provision_logistics_user.py.

ENV CONTRACT (inject via the runtime environment / secrets manager — NEVER in
AGENTS.md, adapterConfig, or an issue thread):
    ODOO_URL        base URL, e.g. https://erp.goldberrygrove.farm  (or
                    http://odoo:8069 from inside the compose network)
    ODOO_DB         database name, e.g. grove_production
                    (falls back to ODOO_DB_NAME for compatibility)
    ODOO_LOGIN      the scoped API user's login, e.g. logistics-otto@…
    ODOO_API_KEY    that user's Odoo API key (Settings ▸ Account Security ▸
                    New API Key). Used as the XML-RPC password.

USAGE
-----
    odoo_client.py check
    odoo_client.py fields  <model> [--attrs string,type,required]
    odoo_client.py search  <model> --domain '[["type","=","product"]]' [--limit 50]
    odoo_client.py read    <model> --ids 1,2,3 [--fields name,qty_available]
    odoo_client.py search-read <model> --domain '[...]' [--fields ...] [--limit 50]
    odoo_client.py count   <model> [--domain '[...]']
    odoo_client.py create  <model> --values '{"name":"…"}' --confirm
    odoo_client.py write   <model> --ids 5 --values '{"list_price":9.5}' --confirm

Domains and values are JSON. Output is JSON on stdout; diagnostics go to stderr.
Exit code is non-zero on any error so heartbeats can detect failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xmlrpc.client

# --------------------------------------------------------------------------- #
# Access policy — the single source of truth for what Otto may touch.
# --------------------------------------------------------------------------- #

# Models readable through this tool (search / read / search-read / fields / count).
READ_MODELS = {
    # Products & master data
    "product.template",
    "product.product",
    "product.category",
    "product.pricelist",
    "product.pricelist.item",
    "product.supplierinfo",
    "product.packaging",
    "uom.uom",
    "uom.category",
    # Inventory
    "stock.quant",
    "stock.move",
    "stock.move.line",
    "stock.picking",
    "stock.picking.type",
    "stock.location",
    "stock.warehouse",
    "stock.warehouse.orderpoint",
    "stock.lot",
    "stock.scrap",
    # Purchasing
    "purchase.order",
    "purchase.order.line",
    # Sales (read-only: needed for fulfilment + reconciliation)
    "sale.order",
    "sale.order.line",
    # Shipping
    "delivery.carrier",
    "stock.package.type",
    # Partners (vendors/customers — read-only)
    "res.partner",
    # Reconciliation surface (read-only) — Stripe/Shippo ↔ Odoo
    "account.move",
    "account.move.line",
    "account.payment",
    "payment.transaction",
}

# Models writable through this tool (create / write, with --confirm).
# Deliberately a subset of READ_MODELS: the master data + inventory + purchasing
# a logistics/inventory specialist owns. Money, CRM and sales stay read-only.
WRITE_MODELS = {
    "product.template",
    "product.product",
    "product.category",
    "product.pricelist",
    "product.pricelist.item",
    "product.supplierinfo",
    "product.packaging",
    "stock.quant",
    "stock.move",
    "stock.move.line",
    "stock.picking",
    "stock.warehouse.orderpoint",
    "stock.lot",
    "stock.scrap",
    "purchase.order",
    "purchase.order.line",
    "delivery.carrier",
    "stock.package.type",
}

# Methods that are never allowed, regardless of model.
BLOCKED_METHODS = {"unlink"}

# Field-level write guard — even on a *writable* model, some fields commit
# spend or cross a governance boundary and must not be set through this tool.
#
# purchase.order: this skill may build & edit PO *drafts* freely, but
# confirming a PO (state -> 'purchase'/'done') commits binding spend, which is
# CFO-only (routes through Penny; landed-cost review). We refuse any write that
# touches `state` on a purchase order so Otto can draft + hand off without ever
# binding spend himself. The confirmation itself happens through a separate,
# CFO-owned path — not by writing `state` here and not via button_confirm
# (which this tool does not expose at all).
WRITE_FIELD_BLOCKLIST = {
    "purchase.order": {"state"},
}


class AccessError(Exception):
    """Raised when a call violates the local access policy."""


def _log(*args: object) -> None:
    print("[odoo_client]", *args, file=sys.stderr, flush=True)


def _die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    _log("ERROR:", msg)
    sys.exit(code)


# --------------------------------------------------------------------------- #
# Connection
# --------------------------------------------------------------------------- #

class Odoo:
    def __init__(self) -> None:
        self.url = (os.environ.get("ODOO_URL") or "").rstrip("/")
        self.db = os.environ.get("ODOO_DB") or os.environ.get("ODOO_DB_NAME") or ""
        self.login = os.environ.get("ODOO_LOGIN") or ""
        self.api_key = os.environ.get("ODOO_API_KEY") or ""
        missing = [
            name
            for name, val in (
                ("ODOO_URL", self.url),
                ("ODOO_DB", self.db),
                ("ODOO_LOGIN", self.login),
                ("ODOO_API_KEY", self.api_key),
            )
            if not val
        ]
        if missing:
            _die(
                "missing required env: "
                + ", ".join(missing)
                + " — these must be injected via the runtime/secrets manager, "
                "not stored in agent config."
            )
        self._uid: int | None = None
        self._models: xmlrpc.client.ServerProxy | None = None

    @property
    def uid(self) -> int:
        if self._uid is None:
            common = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/common")
            uid = common.authenticate(self.db, self.login, self.api_key, {})
            if not uid:
                _die(
                    "authentication failed — check ODOO_LOGIN / ODOO_API_KEY / "
                    "ODOO_DB against the running Odoo."
                )
            self._uid = int(uid)
        return self._uid

    @property
    def models(self) -> xmlrpc.client.ServerProxy:
        if self._models is None:
            self._models = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/object")
        return self._models

    def execute(self, model: str, method: str, args: list, kwargs: dict | None = None):
        return self.models.execute_kw(
            self.db, self.uid, self.api_key, model, method, args, kwargs or {}
        )


# --------------------------------------------------------------------------- #
# Policy guards
# --------------------------------------------------------------------------- #

def _guard_read(model: str) -> None:
    if model not in READ_MODELS:
        raise AccessError(
            f"model '{model}' is not on the logistics read allow-list. "
            "Ask Engineering (GOL-57) to add it if you genuinely need it."
        )


def _guard_write(model: str, method: str, confirm: bool) -> None:
    if method in BLOCKED_METHODS:
        raise AccessError(f"method '{method}' is blocked by policy (destructive).")
    if model not in WRITE_MODELS:
        raise AccessError(
            f"model '{model}' is read-only through this tool "
            "(money/CRM/sales are intentionally not writable here)."
        )
    if not confirm:
        raise AccessError(
            f"'{method}' on '{model}' is a mutating call — re-run with --confirm."
        )


def _guard_write_fields(model: str, values: dict) -> None:
    """Reject writes that touch a governance-gated field on a writable model."""
    blocked = WRITE_FIELD_BLOCKLIST.get(model)
    if not blocked:
        return
    hit = blocked.intersection(values)
    if hit:
        raise AccessError(
            f"field(s) {sorted(hit)} on '{model}' are governance-gated and cannot "
            "be set through this tool. Confirming a purchase order commits binding "
            "spend (CFO-only, routes through Penny) — draft the PO here and hand "
            "off the confirmation."
        )


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

def _parse_json(label: str, raw: str | None, default):
    if raw is None:
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        _die(f"invalid JSON for {label}: {exc}")


def _emit(obj) -> None:
    json.dump(obj, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


def cmd_check(odoo: Odoo, _args) -> None:
    version = xmlrpc.client.ServerProxy(f"{odoo.url}/xmlrpc/2/common").version()
    _emit(
        {
            "ok": True,
            "url": odoo.url,
            "db": odoo.db,
            "login": odoo.login,
            "uid": odoo.uid,
            "server_version": version.get("server_version"),
            "read_models": sorted(READ_MODELS),
            "write_models": sorted(WRITE_MODELS),
        }
    )


def cmd_fields(odoo: Odoo, args) -> None:
    _guard_read(args.model)
    attrs = args.attrs.split(",") if args.attrs else ["string", "type", "required", "readonly"]
    res = odoo.execute(args.model, "fields_get", [], {"attributes": attrs})
    _emit(res)


def cmd_search(odoo: Odoo, args) -> None:
    _guard_read(args.model)
    domain = _parse_json("--domain", args.domain, [])
    ids = odoo.execute(
        args.model, "search", [domain], {"limit": args.limit, "offset": args.offset}
    )
    _emit(ids)


def cmd_count(odoo: Odoo, args) -> None:
    _guard_read(args.model)
    domain = _parse_json("--domain", args.domain, [])
    _emit(odoo.execute(args.model, "search_count", [domain]))


def cmd_read(odoo: Odoo, args) -> None:
    _guard_read(args.model)
    ids = [int(x) for x in args.ids.split(",") if x.strip()]
    fields = args.fields.split(",") if args.fields else []
    kwargs = {"fields": fields} if fields else {}
    _emit(odoo.execute(args.model, "read", [ids], kwargs))


def cmd_search_read(odoo: Odoo, args) -> None:
    _guard_read(args.model)
    domain = _parse_json("--domain", args.domain, [])
    fields = args.fields.split(",") if args.fields else []
    kwargs = {"limit": args.limit, "offset": args.offset}
    if fields:
        kwargs["fields"] = fields
    if args.order:
        kwargs["order"] = args.order
    _emit(odoo.execute(args.model, "search_read", [domain], kwargs))


def cmd_create(odoo: Odoo, args) -> None:
    _guard_write(args.model, "create", args.confirm)
    values = _parse_json("--values", args.values, None)
    if not isinstance(values, dict):
        _die("--values must be a JSON object for create")
    _guard_write_fields(args.model, values)
    _log(f"CREATE {args.model} <- {json.dumps(values)}")
    _emit(odoo.execute(args.model, "create", [values]))


def cmd_write(odoo: Odoo, args) -> None:
    _guard_write(args.model, "write", args.confirm)
    ids = [int(x) for x in args.ids.split(",") if x.strip()]
    values = _parse_json("--values", args.values, None)
    if not isinstance(values, dict):
        _die("--values must be a JSON object for write")
    if not ids:
        _die("--ids is required for write")
    _guard_write_fields(args.model, values)
    _log(f"WRITE {args.model} ids={ids} <- {json.dumps(values)}")
    _emit(odoo.execute(args.model, "write", [ids, values]))


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="odoo_client.py", description=__doc__.split("\n")[1])
    sub = p.add_subparsers(dest="command", required=True)

    def add_model(sp):
        sp.add_argument("model", help="Odoo model, e.g. product.template")

    c = sub.add_parser("check", help="verify connectivity + auth, print policy")
    c.set_defaults(func=cmd_check)

    c = sub.add_parser("fields", help="list a model's fields")
    add_model(c)
    c.add_argument("--attrs", default=None, help="comma list of field attributes")
    c.set_defaults(func=cmd_fields)

    c = sub.add_parser("search", help="search ids by domain")
    add_model(c)
    c.add_argument("--domain", default=None, help="JSON Odoo domain")
    c.add_argument("--limit", type=int, default=80)
    c.add_argument("--offset", type=int, default=0)
    c.set_defaults(func=cmd_search)

    c = sub.add_parser("count", help="search_count by domain")
    add_model(c)
    c.add_argument("--domain", default=None, help="JSON Odoo domain")
    c.set_defaults(func=cmd_count)

    c = sub.add_parser("read", help="read records by id")
    add_model(c)
    c.add_argument("--ids", required=True, help="comma list of ids")
    c.add_argument("--fields", default=None, help="comma list of fields")
    c.set_defaults(func=cmd_read)

    c = sub.add_parser("search-read", help="search + read in one call")
    add_model(c)
    c.add_argument("--domain", default=None, help="JSON Odoo domain")
    c.add_argument("--fields", default=None, help="comma list of fields")
    c.add_argument("--limit", type=int, default=80)
    c.add_argument("--offset", type=int, default=0)
    c.add_argument("--order", default=None, help="e.g. 'write_date desc'")
    c.set_defaults(func=cmd_search_read)

    c = sub.add_parser("create", help="create a record (gated, --confirm)")
    add_model(c)
    c.add_argument("--values", required=True, help="JSON object of field values")
    c.add_argument("--confirm", action="store_true", help="required to mutate")
    c.set_defaults(func=cmd_create)

    c = sub.add_parser("write", help="write fields on records (gated, --confirm)")
    add_model(c)
    c.add_argument("--ids", required=True, help="comma list of ids")
    c.add_argument("--values", required=True, help="JSON object of field values")
    c.add_argument("--confirm", action="store_true", help="required to mutate")
    c.set_defaults(func=cmd_write)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        odoo = Odoo()
        args.func(odoo, args)
    except AccessError as exc:
        _die(f"policy: {exc}", code=3)
    except xmlrpc.client.Fault as exc:
        _die(f"odoo fault: {exc.faultString}", code=4)
    except (xmlrpc.client.ProtocolError, ConnectionError, OSError) as exc:
        _die(f"transport: {exc}", code=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
