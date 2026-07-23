# Synthetic Tier-1 journey: cart add → cart get for one tenant.
# Exercises the BFF↔Odoo write path that the read journeys can't: POST adds a
# line to a session cart (website_sale), then GET must reflect it. Hurl
# preserves the session cookie across entries in this file, so the GET sees the
# same cart the POST created.
# Catches: BFF↔Odoo session break, cart proxy / company-scoping regressions.
# Side effect: creates a draft cart sale.order per run (same as a real shopper
# abandoning a cart — Odoo expires these; not a confirmed sale).

GET {{odoo_base}}/grove/api/v1/products
X-Grove-Tenant: {{tenant}}
HTTP 200
[Captures]
product_id: jsonpath "$.results[0].id"

POST {{odoo_base}}/grove/api/v1/cart
X-Grove-Tenant: {{tenant}}
Content-Type: application/json
{
  "product_id": {{product_id}},
  "quantity": 1
}
HTTP 200
[Asserts]
jsonpath "$.lines" count > 0
jsonpath "$.lines[0].product_id" exists
jsonpath "$.lines[0].quantity" >= 1

GET {{odoo_base}}/grove/api/v1/cart
X-Grove-Tenant: {{tenant}}
HTTP 200
[Asserts]
jsonpath "$.lines" count > 0
