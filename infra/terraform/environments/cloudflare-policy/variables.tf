variable "cloudflare_api_token" {
  description = "Cloudflare API token. Needs Zone -> Zone -> Read AND Zone -> Firewall Services -> Edit on every zone in var.zone_names. From GoldberryGrove Infra / cloudflare_api_token."
  type        = string
  sensitive   = true
}

variable "zone_names" {
  description = "Cloudflare zones that get the edge policy rules. Only list zones that actually exist on the account -- the data lookup fails loudly for missing ones (that's the point: a typo'd or not-yet-migrated domain should break the plan, not silently skip protection)."
  type        = set(string)
  default = [
    "atthegrovenursery.com",
    "gatheringatthegrove.com",
    "goldberrygrove.farm",
    "woodworkingeorge.com",
  ]
}

variable "blocked_countries" {
  description = "ISO 3166-1 alpha-2 country codes whose traffic is blocked at the Cloudflare edge, on every proxied hostname in every zone. Business rationale 2026-07-04: Grove businesses ship nowhere near CN/RU and both are dominant sources of bot/scanner traffic; blocking at the edge cuts noise before it reaches any origin."
  type        = set(string)
  default     = ["CN", "RU"]

  validation {
    condition     = alltrue([for c in var.blocked_countries : can(regex("^[A-Z]{2}$", c))])
    error_message = "blocked_countries entries must be 2-letter uppercase ISO country codes (e.g. CN, RU)."
  }
}
