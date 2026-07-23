#!/usr/bin/env python3
"""
Provision the least-privilege Odoo user that the logistics agent (Otto)
authenticates as. Run once by an operator who holds Odoo *admin* credentials
(or by DevOps with vault access), against the running Odoo.

What it does (idempotent):
  1. Finds or creates a res.users login `logistics-otto` (Internal User).
  2. Grants ONLY the groups a logistics/inventory specialist needs:
        - Inventory / User        (stock.group_stock_user)
        - Inventory / Manager     (stock.group_stock_manager)   -> adjustments
        - Purchase / User         (purchase.group_purchase_user)
        - Sales / User: own docs  (sales_team.group_sale_salesman)
        - Multi-UoM               (uom.group_uom)
        - Product packaging       (product.group_stock_packaging)
     Explicitly does NOT grant Settings/admin, Accounting, or user-management.
  3. Prints the user id.

What it deliberately does NOT do:
  - It does NOT create the API key. Keys are minted by the private method
    res.users.apikeys._generate, which Odoo's RPC layer refuses to dispatch
    (underscore-prefixed), so it CANNOT be done over XML-RPC from here. Mint
    the key headlessly in an Odoo shell with the companion script:
        odoo shell -d "$ODOO_DB" --no-http < mint_logistics_key.py
    then store it in the secrets manager and inject it as ODOO_API_KEY into
    Otto's runtime env. NEVER paste it into agent config, AGENTS.md, or an
    issue thread.

Admin env contract (for THIS script only — not for Otto):
    ODOO_URL, ODOO_DB (or ODOO_DB_NAME), ODOO_ADMIN_LOGIN, ODOO_ADMIN_API_KEY

Usage:
    ODOO_URL=… ODOO_DB=… ODOO_ADMIN_LOGIN=… ODOO_ADMIN_API_KEY=… \
        provision_logistics_user.py [--login logistics-otto] [--name "Logistics — Otto (agent)"] [--dry-run]

stdlib-only; logs to stderr.
"""

from __future__ import annotations

import argparse
import os
import sys
import xmlrpc.client

GROUP_XMLIDS = [
    "stock.group_stock_user",
    "stock.group_stock_manager",
    "purchase.group_purchase_user",
    "sales_team.group_sale_salesman",
    "uom.group_uom",
    # Product packaging feature — needed to read/write product.packaging
    # (box-fit / carton strategy per product class). Skipped gracefully if the
    # feature flag isn't installed (WARN, not fatal).
    "product.group_stock_packaging",
]


def _log(*a: object) -> None:
    print("[provision]", *a, file=sys.stderr, flush=True)


def _env(name: str, *fallbacks: str) -> str:
    for n in (name, *fallbacks):
        v = os.environ.get(n)
        if v:
            return v
    _log(f"ERROR: missing env {name}")
    sys.exit(2)


def main() -> int:
    ap = argparse.ArgumentParser(description="Provision least-privilege logistics Odoo user")
    ap.add_argument("--login", default="logistics-otto")
    ap.add_argument("--name", default="Logistics — Otto (agent)")
    ap.add_argument("--dry-run", action="store_true", help="report intended changes only")
    args = ap.parse_args()

    url = _env("ODOO_URL").rstrip("/")
    db = _env("ODOO_DB", "ODOO_DB_NAME")
    admin_login = _env("ODOO_ADMIN_LOGIN")
    admin_key = _env("ODOO_ADMIN_API_KEY")

    common = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common")
    uid = common.authenticate(db, admin_login, admin_key, {})
    if not uid:
        _log("ERROR: admin authentication failed")
        return 1
    models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")

    def ex(model, method, args_, kw=None):
        return models.execute_kw(db, uid, admin_key, model, method, args_, kw or {})

    # Resolve group ids from xml_ids.
    group_ids = []
    for xmlid in GROUP_XMLIDS:
        module, name = xmlid.split(".", 1)
        rec = ex(
            "ir.model.data",
            "search_read",
            [[["module", "=", module], ["name", "=", name]]],
            {"fields": ["res_id", "model"], "limit": 1},
        )
        if not rec or rec[0]["model"] != "res.groups":
            _log(f"WARN: group xml_id not found (module not installed?): {xmlid}")
            continue
        group_ids.append(rec[0]["res_id"])
    _log(f"resolved {len(group_ids)} groups: {group_ids}")

    existing = ex(
        "res.users",
        "search_read",
        [[["login", "=", args.login]]],
        {"fields": ["id", "name", "groups_id"], "limit": 1},
    )

    if args.dry_run:
        action = "update groups on" if existing else "create"
        _log(f"DRY-RUN: would {action} user '{args.login}' with groups {group_ids}")
        return 0

    if existing:
        user_id = existing[0]["id"]
        ex("res.users", "write", [[user_id], {"groups_id": [(4, gid) for gid in group_ids]}])
        _log(f"updated existing user id={user_id}, ensured logistics groups")
    else:
        user_id = ex(
            "res.users",
            "create",
            [
                {
                    "name": args.name,
                    "login": args.login,
                    "groups_id": [(6, 0, group_ids)],
                }
            ],
        )
        _log(f"created user id={user_id}")

    print(user_id)
    _log(
        "NEXT: mint this user's API key headlessly — "
        "`odoo shell -d $ODOO_DB --no-http < mint_logistics_key.py` — then "
        "store it in the secrets manager and inject ODOO_LOGIN + ODOO_API_KEY "
        "into Otto's runtime env."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
