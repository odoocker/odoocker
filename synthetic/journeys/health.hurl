# Synthetic Tier-1 journey: grove_headless API is alive.
# Shared (not tenant-scoped) — the health route is auth="none".
# Catches: grove_headless module not loaded / Odoo backend down.
GET {{odoo_base}}/grove/api/v1/health
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"
