output "droplet_id" {
  description = "DigitalOcean Droplet ID"
  value       = digitalocean_droplet.this.id
}

output "ipv4_address" {
  description = "Public IPv4 address of the Droplet"
  value       = digitalocean_droplet.this.ipv4_address
}

output "volume_id" {
  description = "ID of the attached volume, or null if no volume was created (volume_size_gb = 0)."
  value       = var.volume_size_gb > 0 ? digitalocean_volume.this[0].id : null
}
