output "preview_urls" {
  description = "URL per tenant — reviewers receive these in the PR comment posted by preview-up.yml."
  value = {
    for tenant in ["hub", "goldberry", "ggg", "nursery", "odoo"] :
    tenant => "https://${tenant}.${local.preview_host}.${local.preview_zone}"
  }
}

output "droplet_ip" {
  description = "Public IPv4 of the preview droplet — for SSH (root@<ip>) and direct admin."
  value       = module.droplet.ipv4_address
}

output "preview_host" {
  description = "Preview host label (e.g. pr-104-x7q2k). Useful for downstream tagging and grep-on-cleanup."
  value       = local.preview_host
}

output "monthly_cost_estimate_usd" {
  description = "Rough cost while this preview is up. Close the PR (or wait 7d auto-destroy) to stop the meter."
  value       = "$0.033/hr (~$24/mo prorated). Close PR to destroy."
}
