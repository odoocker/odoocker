output "obs_droplet_ip" {
  description = "Public IPv4 of the observability droplet."
  value       = module.obs_droplet.ipv4_address
}

output "obs_droplet_id" {
  description = "ID of the observability droplet."
  value       = module.obs_droplet.droplet_id
}

output "openobserve_url" {
  description = "OpenObserve UI (admin-only via the firewall)."
  value       = "http://${module.obs_droplet.ipv4_address}:5080"
}

output "keep_url" {
  description = "Keep UI (admin-only via the firewall)."
  value       = "http://${module.obs_droplet.ipv4_address}:3034"
}
