output "blogs_droplet_ip" {
  description = "Public IPv4 of the blogs droplet (apex + blog.* records point here)."
  value       = digitalocean_droplet.blogs.ipv4_address
}

output "blog_urls" {
  description = "The four blog.* hostnames."
  value       = { for k, z in local.tenants : k => "https://blog.${z}" }
}

output "backups_bucket" {
  description = "Spaces bucket receiving nightly blog backups."
  value       = digitalocean_spaces_bucket.blogs_backups.name
}
