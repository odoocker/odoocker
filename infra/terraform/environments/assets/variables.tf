# === Provider credentials (sensitive — TF_VAR_* via op run) ===

variable "do_token" {
  description = "DigitalOcean API token. Scopes: spaces:read, spaces:write, cdn:read, cdn:write. From GoldberryGrove Infra / do_token."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to gatheringatthegrove.com with Zone:DNS:Edit. From GoldberryGrove Infra / cloudflare_api_token."
  type        = string
  sensitive   = true
}

# === Layout (has defaults; override only if migrating zones/regions) ===

variable "region" {
  description = "DigitalOcean Spaces region. nyc3 matches the rest of Grove's infra + minimizes cross-region latency to the Odoo droplet (which serves product image URLs pointing here)."
  type        = string
  default     = "nyc3"
}

variable "cloudflare_zone_name" {
  description = "Apex zone in Cloudflare. Bucket CNAME will be attached under this zone as assets.<zone>."
  type        = string
  default     = "gatheringatthegrove.com"
}

variable "assets_subdomain" {
  description = "Subdomain to serve assets under. Final FQDN: <assets_subdomain>.<cloudflare_zone_name>. Frontends read NEXT_PUBLIC_ASSETS_URL=https://<this>/ and construct per-tenant paths."
  type        = string
  default     = "assets"
}

variable "bucket_name" {
  description = "Spaces bucket name. Must be globally unique across DO Spaces (like S3 buckets). Names starting with `grove-` scope to this project."
  type        = string
  default     = "grove-assets"
}

variable "tenant_prefixes" {
  description = "Per-tenant path prefixes inside the bucket. Uploads go to grove-assets/<tenant>/... via the upload script. Frontends fetch via NEXT_PUBLIC_ASSETS_URL + '/' + tenant + '/' + path. Adding a new tenant here doesn't create anything in the bucket automatically -- it just documents the intent; the first upload creates the prefix implicitly."
  type        = list(string)
  default     = ["hub", "goldberry", "ggg", "nursery", "shared"]
}

# === CORS ===

variable "cors_allowed_origins" {
  description = "Origins allowed to fetch assets via cross-origin requests. Include every frontend hostname that references `assets.<zone>` in its markup. `*` would work but is broader than needed. Update this when Level 3 App Platform apps come online + when the DNS-cutover flips *.qa-l3 to *.qa."
  type        = list(string)
  default = [
    # Public production hostnames (future)
    "https://gatheringatthegrove.com",
    "https://goldberrygrove.farm",
    "https://woodworkingeorge.com",
    "https://atthegrovenursery.com",
    # QA -- monolith
    "https://qa.gatheringatthegrove.com",
    "https://*.qa.gatheringatthegrove.com",
    # QA -- Level 3
    "https://qa-l3.gatheringatthegrove.com",
    "https://*.qa-l3.gatheringatthegrove.com",
    # Local dev
    "http://localhost:3001",
    "http://localhost:3002",
    "http://localhost:3003",
    "http://localhost:3004",
  ]
}

# === CDN ===

variable "cdn_ttl_seconds" {
  description = "Edge cache TTL for the CDN. 3600 = 1hr, a reasonable balance between propagation speed after uploads and cache hit rate. Individual assets can override via the upload script setting Cache-Control headers."
  type        = number
  default     = 3600
}
