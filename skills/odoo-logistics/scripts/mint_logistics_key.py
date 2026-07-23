# -*- coding: utf-8 -*-
"""
Mint the `logistics-otto` Odoo API key HEADLESSLY — no self-service UI, no human
login. This is the companion to provision_logistics_user.py: run the provisioner
first (creates the least-privilege user over XML-RPC), then run THIS to generate
the user's `rpc`-scoped API key.

WHY THIS IS A SHELL SCRIPT, NOT XML-RPC
    res.users.apikeys._generate is a *private* method (leading underscore).
    Odoo's RPC dispatcher refuses to call any method whose name starts with "_",
    so you CANNOT mint a key through execute_kw / the provisioner. It must run
    in-process, inside an Odoo shell, where `env` is already bound:

        docker compose exec -T odoo \
            odoo shell -d "$ODOO_DB" --no-http --logfile=/dev/null \
            < skills/odoo-logistics/scripts/mint_logistics_key.py

    (equivalently: `cat mint_logistics_key.py | docker compose exec -T odoo
    odoo shell -d "$ODOO_DB" --no-http`.)

WHAT IT PRINTS
    The plaintext key ONCE, on stdout, between markers:
        ----BEGIN LOGISTICS_OTTO_API_KEY----
        <key>
        ----END LOGISTICS_OTTO_API_KEY----
    Odoo only stores a hash — the key is never recoverable after this. Capture
    it, put it in the secrets manager, inject it as ODOO_API_KEY into Otto's
    runtime env, then clear your scrollback. NEVER paste it into agent config,
    AGENTS.md, or an issue thread.

IDEMPOTENT
    Any prior key named LOGISTICS_KEY_NAME owned by this user is revoked before a
    fresh one is minted, so re-running always leaves exactly one working key of
    known provenance (safe rotation / recovery).

VERSION-ROBUST
    _generate gained an `expiration_date` parameter in Odoo 17; this introspects
    the live signature and only passes it when present, so the same script works
    on Odoo 16/17/18/19 without edits.
"""

import inspect
import sys

LOGISTICS_LOGIN = "logistics-otto"
LOGISTICS_KEY_NAME = "otto-logistics-runtime"
SCOPE = "rpc"  # the scope Odoo checks when authenticating XML-RPC/JSON-RPC


def _err(*a):
    print("[mint]", *a, file=sys.stderr, flush=True)


# `env` is injected by `odoo shell`. Fail loudly if we're run the wrong way.
try:
    env  # noqa: F821  (provided by the shell namespace)
except NameError:
    _err(
        "ERROR: `env` is not defined. Run this INSIDE an Odoo shell, e.g.\n"
        "  docker compose exec -T odoo odoo shell -d \"$ODOO_DB\" --no-http "
        "< mint_logistics_key.py"
    )
    raise SystemExit(2)


def main():
    user = env["res.users"].search([("login", "=", LOGISTICS_LOGIN)], limit=1)
    if not user:
        _err(
            f"ERROR: user '{LOGISTICS_LOGIN}' not found. "
            "Run provision_logistics_user.py first."
        )
        return 2

    Apikeys = env["res.users.apikeys"].sudo()

    # Revoke prior keys with our marker name (idempotent re-run / rotation).
    # Delete via SQL, which is how Odoo core removes keys — ORM unlink and the
    # public remove() path are gated by an identity re-check we can't satisfy
    # non-interactively in a shell.
    prior = Apikeys.search(
        [("user_id", "=", user.id), ("name", "=", LOGISTICS_KEY_NAME)]
    )
    if prior:
        _err(f"revoking {len(prior)} prior key(s) named '{LOGISTICS_KEY_NAME}'")
        env.cr.execute(
            "DELETE FROM res_users_apikeys WHERE id IN %s", (tuple(prior.ids),)
        )
        Apikeys.invalidate_model()

    # Mint as the target user so the key is owned by logistics-otto, not admin.
    generate = env["res.users.apikeys"].with_user(user)._generate
    kwargs = {}
    if "expiration_date" in inspect.signature(generate).parameters:
        kwargs["expiration_date"] = False  # non-expiring service credential
    key = generate(SCOPE, LOGISTICS_KEY_NAME, **kwargs)

    env.cr.commit()

    print("----BEGIN LOGISTICS_OTTO_API_KEY----")
    print(key)
    print("----END LOGISTICS_OTTO_API_KEY----")
    _err(
        "minted OK for uid="
        f"{user.id} login='{LOGISTICS_LOGIN}' scope='{SCOPE}'. "
        "Store in secrets manager, inject as ODOO_API_KEY, clear scrollback."
    )
    return 0


raise SystemExit(main())
