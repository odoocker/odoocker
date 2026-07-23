# Synthetic Tier-1 journey: checkout-canary — the money path.
# Creates a $0 order for the shared SYNTHETIC-CANARY variant via the bearer
# /orders endpoint, then verifies the access_token gate on order_get.
# variant_id + api_key are injected by run.py (variant resolved via XML-RPC,
# key via a variables-file so it stays out of argv). The draft order this
# creates is swept by run.py's XML-RPC cleanup after the run.
# Catches: /orders bearer auth broken, order creation broken, PII access_token
# gate regressed.

POST {{odoo_base}}/grove/api/v1/orders
X-Grove-Tenant: {{tenant}}
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "contact": {
    "name": "Synthetic Canary",
    "email": "synthetic-canary@grove.invalid"
  },
  "payment_method": "card",
  "items": [
    { "variant_id": {{variant_id}}, "quantity": 1 }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.id" isInteger
jsonpath "$.access_token" exists
jsonpath "$.amount_total" == 0
jsonpath "$.line_count" == 1
[Captures]
order_id: jsonpath "$.id"
order_token: jsonpath "$.access_token"

# access_token gate — WITH the token → 200.
GET {{odoo_base}}/grove/api/v1/orders/{{order_id}}?access_token={{order_token}}
X-Grove-Tenant: {{tenant}}
HTTP 200

# access_token gate — WITHOUT the token → 403 (id-enumeration PII guard holds).
GET {{odoo_base}}/grove/api/v1/orders/{{order_id}}
X-Grove-Tenant: {{tenant}}
HTTP 403
