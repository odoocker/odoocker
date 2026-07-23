output "droplet_id" {
  description = "Sandbox Droplet ID"
  value       = module.sandbox.droplet_id
}

output "ipv4_address" {
  description = "Public IPv4 address of the sandbox Droplet"
  value       = module.sandbox.ipv4_address
}

output "volume_id" {
  description = "Block storage volume ID"
  value       = module.sandbox.volume_id
}

output "ssh_command" {
  description = "SSH command to connect to the sandbox Droplet"
  value       = "ssh root@${module.sandbox.ipv4_address}"
}

output "stack_urls" {
  description = "Service URLs (only valid after DNS propagation or /etc/hosts override)"
  value = {
    odoo            = "http://${module.sandbox.ipv4_address}:8069"
    ghost_goldberry = "http://${module.sandbox.ipv4_address}:2368"
    ghost_ggg       = "http://${module.sandbox.ipv4_address}:2369"
    ghost_nursery   = "http://${module.sandbox.ipv4_address}:2370"
  }
}
