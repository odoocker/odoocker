output "spaces_access_key" {
  description = "DO Spaces RW access key for grove-preview-data. Already written to GH secret DO_SPACES_ACCESS_KEY; surfaced here for the prod-droplet install (see /etc/grove/sanitize.env in install-systemd.md)."
  value       = digitalocean_spaces_key.preview_data_rw.access_key
  sensitive   = true
}

output "spaces_secret_key" {
  description = "DO Spaces RW secret key for grove-preview-data. Already written to GH secret DO_SPACES_SECRET_KEY; same install-time use as access_key."
  value       = digitalocean_spaces_key.preview_data_rw.secret_key
  sensitive   = true
}

output "ssh_key_fingerprint" {
  description = "DO SSH key fingerprint. Already written to GH secret PREVIEW_SSH_KEY_ID."
  value       = digitalocean_ssh_key.preview_deploy.fingerprint
}

output "ns_records" {
  description = "Cloudflare-side NS records that delegate the preview subdomain to DigitalOcean. Cross-check propagation with: dig +short NS <preview_domain>"
  value       = [for r in cloudflare_record.preview_ns : r.value]
}

output "preview_domain" {
  description = "The FQDN that DigitalOcean DNS owns post-delegation."
  value       = digitalocean_domain.preview.name
}

output "github_secrets_written" {
  description = "Names of the GH Actions secrets created on var.github_secrets_repo."
  value       = sort([for k, _ in local.gh_secrets : k])
}
