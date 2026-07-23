# -*- coding: utf-8 -*-
"""
Provision the least-privilege `logistics-otto` Odoo user HEADLESSLY, inside an
Odoo shell (full DB context, superuser `env`). Companion to
mint_logistics_key.py: run THIS first (create user + grant scoped groups), then
mint_logistics_key.py to generate the user's API key.

    docker compose exec -T odoo \
        odoo shell -d "$ODOO_DB" --no-http --logfile=/dev/null \
        < skills/odoo-logistics/scripts/provision_logistics_user_shell.py

WHY A SHELL SCRIPT (not the XML-RPC provision_logistics_user.py)
    provision_logistics_user.py authenticates as an Odoo *user* over XML-RPC
    (common.authenticate → needs a res.users login + that user's password or
    API key). On the self-hosted droplets the only admin credential present is
    the Odoo **master password** (odoo.conf `admin_passwd`, from /etc/grove/.env
    ODOO_ADMIN_PASSWORD) — that gates the /web/database management endpoints, it
    is NOT a res.users login credential, so there is nothing for XML-RPC to
    authenticate as. Inside `odoo shell`, `env` already runs as SUPERUSER, so no
    credential is needed at all. This is the mechanism the CEO specified for
    GOL-89 ("provision + mint inside docker compose exec odoo odoo shell").

    The XML-RPC provisioner stays valid for operators who DO hold a real admin
    user login (e.g. a laptop with the bootstrap admin creds); this variant is
    what the automated droplet workflow uses. Group set is kept identical to it.

IDEMPOTENT
    Finds-or-creates login `logistics-otto` and ensures the group set with
    (4, gid) links (additive, never clobbers). Safe to re-run.

DRY RUN
    Set LOGISTICS_DRY_RUN=1 in the container env to print the resolved groups
    and the intended action WITHOUT writing anything (no commit). Used to paste
    a redacted scope preview before the live run. Prints NOTHING sensitive.

Group set (least privilege — Inventory + Purchase + Sales + UoM only; NO
Settings/admin, NO Accounting, NO user-management):
    stock.group_stock_user            Inventory / User
    stock.group_stock_manager         Inventory / Manager (adjustments)
    purchase.group_purchase_user      Purchase / User
    sales_team.group_sale_salesman    Sales / User: own documents
    uom.group_uom                     Multi-UoM
    product.group_stock_packaging     Product packaging (skipped if not installed)
"""

import os
import sys

LOGISTICS_LOGIN = "logistics-otto"
LOGISTICS_NAME = "Logistics — Otto (agent)"
DRY_RUN = os.environ.get("LOGISTICS_DRY_RUN", "").strip() not in ("", "0", "false", "False")

# Kept byte-for-byte in sync with provision_logistics_user.py's GROUP_XMLIDS.
GROUP_XMLIDS = [
    "stock.group_stock_user",
    "stock.group_stock_manager",
    "purchase.group_purchase_user",
    "sales_team.group_sale_salesman",
    "uom.group_uom",
    "product.group_stock_packaging",
]


def _err(*a):
    print("[provision]", *a, file=sys.stderr, flush=True)


# `env` is injected by `odoo shell`. Fail loudly if we're run the wrong way.
try:
    env  # noqa: F821  (provided by the shell namespace)
except NameError:
    _err(
        "ERROR: `env` is not defined. Run this INSIDE an Odoo shell, e.g.\n"
        "  docker compose exec -T odoo odoo shell -d \"$ODOO_DB\" --no-http "
        "< provision_logistics_user_shell.py"
    )
    raise SystemExit(2)


def main():
    # Resolve group xml_ids → ids; a not-installed optional feature (e.g.
    # product packaging) is a WARN, not fatal — mirrors the XML-RPC provisioner.
    group_ids = []
    for xmlid in GROUP_XMLIDS:
        rec = env.ref(xmlid, raise_if_not_found=False)
        if not rec or rec._name != "res.groups":
            _err(f"WARN: group xml_id not found (module not installed?): {xmlid}")
            continue
        group_ids.append(rec.id)
        _err(f"resolved {xmlid} -> res.groups({rec.id})")
    _err(f"resolved {len(group_ids)}/{len(GROUP_XMLIDS)} groups: {group_ids}")

    user = env["res.users"].search([("login", "=", LOGISTICS_LOGIN)], limit=1)

    if DRY_RUN:
        action = "UPDATE groups on existing" if user else "CREATE"
        _err(
            f"DRY-RUN: would {action} user '{LOGISTICS_LOGIN}' "
            f"({'uid=%d' % user.id if user else 'new'}) with the "
            f"{len(group_ids)} groups above. No write, no commit."
        )
        print("----BEGIN LOGISTICS_OTTO_SCOPE_DRYRUN----")
        print(f"login={LOGISTICS_LOGIN}")
        print(f"action={action}")
        for xmlid in GROUP_XMLIDS:
            rec = env.ref(xmlid, raise_if_not_found=False)
            status = "granted" if (rec and rec._name == "res.groups") else "SKIP(not-installed)"
            print(f"group {xmlid} -> {status}")
        print("admin/accounting/settings/user-management = NOT granted")
        print("----END LOGISTICS_OTTO_SCOPE_DRYRUN----")
        return 0

    if user:
        user.write({"groups_id": [(4, gid) for gid in group_ids]})
        _err(f"updated existing user uid={user.id}, ensured logistics groups")
    else:
        user = env["res.users"].create(
            {
                "name": LOGISTICS_NAME,
                "login": LOGISTICS_LOGIN,
                "groups_id": [(6, 0, group_ids)],
            }
        )
        _err(f"created user uid={user.id}")

    env.cr.commit()
    print(f"LOGISTICS_OTTO_UID={user.id}")
    _err(
        f"provisioned OK uid={user.id} login='{LOGISTICS_LOGIN}' "
        f"groups={len(group_ids)}. NEXT: mint the API key with "
        "mint_logistics_key.py (also in an odoo shell)."
    )
    return 0


raise SystemExit(main())
