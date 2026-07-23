# environments/production

ADR-007 Phase 6 production environment. Track 1 (blogs droplet) is live;
Managed PG / Odoo droplet / App Platform arrive with the Track 2 plan.

## Apply (manual by decision)

1. `cp backend.hcl.example backend.hcl`
2. Create `.env.op` mapping op:// refs -> TF_VAR_* + AWS_* (see qa-app-platform README for the pattern). Required:
   - TF_VAR_do_token, TF_VAR_cloudflare_api_token, TF_VAR_cloudflare_origin_ca_key
   - TF_VAR_spaces_access_id, TF_VAR_spaces_secret_key
   - TF_VAR_admin_ip_cidr, TF_VAR_healthchecks_ping_url
   - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (state backend)
3. `terraform init -backend-config=backend.hcl`
4. `op run --env-file=.env.op -- terraform plan`
5. `op run --env-file=.env.op -- terraform apply`

## What lives here (Track 1)

- Blogs droplet (4x Ghost 6 + MySQL 8 + Caddy) - see blogs.tf
- blog.{zone} DNS records in all four Cloudflare brand zones
- Cloudflare Origin CA certs (15y, per zone) for proxied TLS
- grove-blogs-backups Spaces bucket + lifecycle
- Apex A records for gatheringatthegrove.com + goldberrygrove.farm
  (imported from Cloudflare during migration; see apex-records.tf) (file arrives with the Task 6 migration)

## History

The pre-Level-3 monolith production config that previously lived here
(never applied; "DO NOT DEPLOY YET") was replaced 2026-07 by this
Phase 6 shape per the Grove Production Launch spec.
