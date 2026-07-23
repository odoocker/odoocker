output "geo_block_rulesets" {
  description = "Ruleset IDs per zone, for dashboard cross-referencing and API verification (GET /zones/<zone_id>/rulesets/<id>)."
  value       = { for name, rs in cloudflare_ruleset.geo_block : name => rs.id }
}

output "blocked_countries" {
  description = "Country codes currently blocked at the edge."
  value       = sort(tolist(var.blocked_countries))
}
