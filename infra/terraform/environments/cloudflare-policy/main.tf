###############################################################################
# cloudflare-policy -- account-wide Cloudflare edge policy.
#
# Currently: geo-blocking. One WAF custom rule per zone that BLOCKS all
# traffic whose source country is in var.blocked_countries (CN + RU as of
# 2026-07-04). Free-plan zones get 5 custom rules; this uses 1 per zone.
#
# Scope notes, so nobody over-trusts this:
#   - Applies to PROXIED (orange-cloud) hostnames only. DNS-only records
#     bypass Cloudflare entirely and get no protection here.
#   - The grove-assets raw CDN hostname (grove-assets.nyc3.cdn.
#     digitaloceanspaces.com) is DO's own edge, not a hostname in these
#     zones -- traffic to it is NOT geo-blocked. The vanity assets host
#     (assets.<apex>, proxied + Worker) IS covered: this rule evaluates
#     in the http_request_firewall_custom phase, before Worker routes run.
#   - App Platform apps' *.ondigitalocean.app default ingresses are also
#     outside these zones; their qa-l3 vanity hosts live in the DO-delegated
#     qa-l3 zone, which Cloudflare never sees. Level 3 QA is therefore NOT
#     geo-blocked -- acceptable for QA; revisit for prod cutover (ADR-007
#     Phase 6) when prod hostnames land on proxied Cloudflare records.
#
# Action is `block` (hard 403 from the CF edge) rather than
# `managed_challenge` per operator decision 2026-07-04: these businesses
# have zero legitimate CN/RU audience, so the friction-vs-protection
# trade-off of a challenge buys nothing.
###############################################################################

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "zones" {
  for_each = var.zone_names
  name     = each.value
}

locals {
  # `in` set syntax wants space-separated quoted values: {"CN" "RU"}
  country_set = join(" ", [for c in sort(tolist(var.blocked_countries)) : format("%q", c)])
}

resource "cloudflare_ruleset" "geo_block" {
  for_each = data.cloudflare_zone.zones

  zone_id     = each.value.id
  name        = "Grove edge policy"
  description = "Managed by TF (environments/cloudflare-policy). Do not edit in the dashboard -- changes get reverted on next apply."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "block"
    expression  = "(ip.geoip.country in {${local.country_set}})"
    description = "Block ${join("+", sort(tolist(var.blocked_countries)))} traffic (bot/scanner noise; no legitimate audience)"
    enabled     = true
  }
}
