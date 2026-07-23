# Caddyfile for Level 3 QA - fronts ONLY Odoo. The 4 frontends move to
# App Platform (Phase 2), which handles its own TLS.
#
# ${QA_ZONE} is interpolated by TF templatefile() before cloud-init writes
# this to /etc/grove/Caddyfile. Resulting hostname is `odoo.qa-l3.<apex>`.
#
# Why DNS-01 even though we only have ONE hostname:
#   1. Operator preference - keeps port 80 closeable in a future hardening pass
#   2. Same Caddy module + plugin as monolith QA - single config skill set
#   3. Wildcard-cert option stays open if Phase 3 adds Odoo subdomains
#      (e.g. xmlrpc.odoo.qa-l3.<apex> for the headless API)

{
	# Global ACME settings
	acme_ca {env.ACME_CA}
	# email - explicitly NOT set; Caddy uses a generated account.
	# Set if you want LE expiry notifications routed somewhere.
}

odoo.${QA_ZONE} {
	# DNS-01 challenge via DO API (same plugin grove-caddy bakes in)
	tls {
		dns digitalocean {env.DO_API_TOKEN}
	}

	# Longpolling endpoint - must NOT be buffered/compressed; pass through raw.
	# Odoo's chat + workflow notifications use this.
	@longpoll {
		path /longpolling/*
	}
	reverse_proxy @longpoll odoo:8072

	# Everything else - main Odoo HTTP backend
	reverse_proxy odoo:8069 {
		# Standard reverse-proxy headers Odoo expects (PROXY_MODE=true reads these)
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}
