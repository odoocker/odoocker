# Synthetic Tier-1 journey: product catalog list + detail for one tenant.
# Tenant scoping is via the X-Grove-Tenant header (grove_headless resolves the
# website/company from it). DB-agnostic: the detail step uses an id captured
# from the list, so it works against any seeded catalog.
# Catches: catalog/DB outage, empty company scope, pricing/serialization breakage.

GET {{odoo_base}}/grove/api/v1/products
X-Grove-Tenant: {{tenant}}
HTTP 200
[Asserts]
jsonpath "$.count" exists
jsonpath "$.results" count > 0
[Captures]
product_id: jsonpath "$.results[0].id"

# Detail for the first product. The controller always serializes `variants`
# (default variant always present) and each variant carries `lst_price`, so
# this is the safe "has price" assertion.
GET {{odoo_base}}/grove/api/v1/products/{{product_id}}
X-Grove-Tenant: {{tenant}}
HTTP 200
[Asserts]
jsonpath "$.id" == {{product_id}}
jsonpath "$.variants" count > 0
jsonpath "$.variants[0].lst_price" exists
