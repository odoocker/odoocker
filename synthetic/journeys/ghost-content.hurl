# Synthetic Tier-1 journey: Ghost blog has content (per tenant).
# Hits the Ghost Content API v5 and asserts at least one published post — a
# content-level check beyond the ghost-*-admin availability monitors. ghost_url
# + ghost_key are injected per tenant by run.py (key via a variables-file so it
# stays out of argv).
# Catches: Ghost content key rotated/invalid, blog empty, Content API broken —
# which would make the tenant's /blog page fail even though Ghost is "up".
GET {{ghost_url}}/ghost/api/content/posts/?key={{ghost_key}}&limit=1
HTTP 200
[Asserts]
jsonpath "$.posts" count > 0
jsonpath "$.posts[0].title" exists
