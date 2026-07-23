###############################################################################
# Grove PRODUCTION environment (ADR-007 Phase 6 shape).
#
# Build-out order (Grove Production Launch spec, 2026-07-04):
#   1. blogs.tf      - Ghost blogs droplet + blog.* DNS + backups   (Track 1)
#   2. Managed PG    - (Track 2, later PR)
#   3. Odoo droplet  - (Track 2, later PR)
#   4. App Platform  - (Track 2, later PR)
#
# Track 1 replaces the two hand-managed Ghost snowflake droplets
# (gatheratthegrove-blog-nyc, ghostgoldberrygrove-nyc1). Until the launch
# cutover, the brand apexes continue to serve Ghost - from this env's
# blogs droplet once Tasks 6/7 repoint them.
#
# Apply is MANUAL by decision (no CI apply for production):
#   cd infra/terraform/environments/production
#   terraform init -backend-config=backend.hcl
#   op run --env-file=.env.op -- terraform apply
###############################################################################

provider "digitalocean" {
  token             = var.do_token
  spaces_access_id  = var.spaces_access_id
  spaces_secret_key = var.spaces_secret_key
}

provider "cloudflare" {
  api_token            = var.cloudflare_api_token
  api_user_service_key = var.cloudflare_origin_ca_key
}

locals {
  tags = [
    "env-production",
    "project-grove",
  ]

  # Tenant -> brand zone. Drives blog.* records, origin certs, Ghost URLs.
  tenants = {
    hub       = "gatheringatthegrove.com"
    goldberry = "goldberrygrove.farm"
    ggg       = "woodworkingeorge.com"
    nursery   = "atthegrovenursery.com"
  }
}

data "cloudflare_zone" "brand" {
  for_each = local.tenants
  name     = each.value
}
