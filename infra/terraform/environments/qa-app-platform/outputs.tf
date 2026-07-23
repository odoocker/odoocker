output "odoo_droplet_ip" {
  description = "Public IPv4 of the Odoo droplet. Tag-discoverable as env-qa-l3."
  value       = digitalocean_droplet.odoo.ipv4_address
}

output "odoo_hostname" {
  description = "Canonical Odoo URL. Frontends (Phase 2 App Platform apps) call this for the REST API."
  value       = "https://odoo.${local.qa_zone}"
}

output "qa_zone" {
  description = "The delegated qa-l3 zone FQDN. Apex serves the hub (Phase 2) and is the parent of tenant CNAMEs."
  value       = local.qa_zone
}

output "pg_cluster_id" {
  description = "Managed PG cluster ID. Used by the App Platform apps' Phase 2 spec to attach this DB as a managed resource."
  value       = digitalocean_database_cluster.pg.id
}

output "pg_private_host" {
  description = "Private VPC hostname for the Managed PG cluster. Used by the Odoo droplet's compose env to connect over the private network (no public DB exposure)."
  value       = digitalocean_database_cluster.pg.private_host
  sensitive   = true
}

output "pg_database_name" {
  description = "Name of the Odoo database in the Managed PG cluster."
  value       = digitalocean_database_db.odoo.name
}

output "caddy_data_volume_id" {
  description = "Volume ID of the persistent Caddy /data store. Persists across droplet recreates so LE cert renewals don't burn rate-limit budget."
  value       = digitalocean_volume.caddy_data.id
}

# === Observability outputs ===

output "obs_droplet_ip" {
  description = "Public IPv4 of the observability droplet. Tag-discoverable as env-qa-l3,role-observability."
  value       = digitalocean_droplet.obs.ipv4_address
}

output "openobserve_url" {
  description = "OpenObserve UI URL (admin-only via firewall allowlist). scripts/setup-monitoring.py POSTs monitors/alerts/dashboards here."
  value       = "https://oo.${local.qa_zone}"
}

output "keep_url" {
  description = "Keep alert-routing UI URL (admin-only via firewall allowlist)."
  value       = "https://keep.${local.qa_zone}"
}

# === App Platform (Phase 2) outputs =========================================

output "hub_url" {
  description = "Public URL of the hub App Platform app. Users hit this; DO issues the cert + routes into the App Platform infra automatically once the custom domain propagates."
  value       = "https://hub.${local.qa_zone}"
}

output "hub_app_id" {
  description = "App Platform app ID for the hub. Used by post-deploy verification (doctl apps get <id>), Keep alert routing, and future scripts that need to poll deploy status."
  value       = digitalocean_app.hub.id
}

output "hub_default_ingress" {
  description = "Ingress URL App Platform assigns to the hub app (grove-hub-qa-l3-<random>.ondigitalocean.app). Useful for verifying the app is responding before the custom-domain cert finishes provisioning."
  value       = digitalocean_app.hub.live_url
}

output "tenant_urls" {
  description = "Public URLs of the tenant App Platform apps (goldberry / ggg / nursery)."
  value       = { for k, _ in local.tenant_apps : k => "https://${k}.${local.qa_zone}" }
}

output "tenant_app_ids" {
  description = "App Platform app IDs per tenant. Same uses as hub_app_id: doctl inspection, Keep routing, deploy-status polling."
  value       = { for k, app in digitalocean_app.tenant : k => app.id }
}

output "tenant_default_ingresses" {
  description = "Default *.ondigitalocean.app ingress URLs per tenant, for probing before the custom-domain cert finishes."
  value       = { for k, app in digitalocean_app.tenant : k => app.live_url }
}
