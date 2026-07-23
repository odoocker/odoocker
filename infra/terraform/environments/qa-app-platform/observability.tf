###############################################################################
# Observability droplet (ADR-007 addendum + ADR-008).
#
# Separate failure domain from the Odoo droplet — monitoring outlives an
# app-plane outage. Hosts the OpenObserve + Keep stack (canonical configs
# already in repo at openobserve/ + keep/, deployed via the existing
# docker-compose.monitoring.yml — but adapted here to bundle MinIO inline
# instead of joining the Odoo droplet's network, since they're on
# separate hosts in Level 3).
#
# Phase 1.5 scope: provision the droplet + DNS + firewall + cloud-init
# that brings up the monitoring stack. Bootstrap of the actual monitors/
# alerts/dashboards/workflows happens via scripts/setup-monitoring.py
# wired into qa-deploy-l3.yml (Phase 2 territory).
#
# DEFERRED (later phase):
#   - Cloudflare-WAF-protected OTLP ingest subdomain (needs CF zone work)
#   - Beyla eBPF sidecar on the Odoo droplet (modifies the Odoo cloud-init)
#   - OTel Collector on the Odoo droplet
###############################################################################

# ── Obs droplet ─────────────────────────────────────────────────────────────

resource "digitalocean_droplet" "obs" {
  name   = "grove-qa-l3-obs"
  size   = var.obs_droplet_size
  image  = var.droplet_image
  region = var.region
  tags   = concat(local.tags, ["role-observability"])

  ssh_keys = [
    data.digitalocean_ssh_key.qa_deploy.fingerprint,
    data.digitalocean_ssh_key.qa_admin.fingerprint,
  ]

  user_data = templatefile("${path.module}/cloud-init-obs.yaml.tpl", {
    qa_zone            = local.qa_zone
    openobserve_tag    = var.openobserve_tag
    keep_tag           = var.keep_tag
    do_token_for_caddy = var.do_token
    acme_endpoint      = var.acme_endpoint

    # base64-encode the obs compose YAML + Caddyfile, same pattern as
    # the Odoo droplet (ADR-005 PR-B — bypasses cloud-init YAML parser
    # for anything with awkward characters in embedded content).
    compose_yml_b64   = base64encode(file("${path.module}/compose/docker-compose.obs.yml"))
    caddyfile_tpl_b64 = base64encode(replace(file("${path.module}/compose/Caddyfile-obs.tpl"), "$${QA_ZONE}", local.qa_zone))
  })

  monitoring = false

  timeouts {
    create = "15m"
    delete = "15m"
  }
}

# ── DNS records for the obs UIs ─────────────────────────────────────────────
# Both Keep + OpenObserve UIs are admin-only (firewalled by IP allowlist
# in the firewall block below). Cert issuance via DNS-01 wildcard would
# be cleaner but adds an LE identifier; for two admin-only subdomains we
# can issue individual certs cheaply (2 LE identifiers, 2 renewals/year).

resource "digitalocean_record" "oo" {
  domain = digitalocean_domain.qa.name
  type   = "A"
  name   = "oo"
  value  = digitalocean_droplet.obs.ipv4_address
  ttl    = 300
}

resource "digitalocean_record" "keep" {
  domain = digitalocean_domain.qa.name
  type   = "A"
  name   = "keep"
  value  = digitalocean_droplet.obs.ipv4_address
  ttl    = 300
}

# ── Firewall (obs droplet) ──────────────────────────────────────────────────
# Tighter than the Odoo droplet's: admin-only for 22 + 443. Port 80 is
# open globally only to satisfy LE HTTP-01 fallback (DNS-01 is preferred
# but HTTP-01 is the standard backstop).
#
# OTLP ingest (port 4318 HTTP / 4317 gRPC) is intentionally NOT exposed
# here — the App Platform frontends ship traces via OTEL_EXPORTER_OTLP_
# ENDPOINT, which (per addendum) goes through Cloudflare WAF in front
# of this droplet. CF-WAF setup is deferred to a follow-up; until then,
# the Phase 2 apps will use synthetic alerting only (OpenObserve checks
# their public URLs from this droplet's outbound side).

resource "digitalocean_firewall" "obs" {
  name        = "grove-qa-l3-obs-fw"
  droplet_ids = [digitalocean_droplet.obs.id]

  # SSH — operator only
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_ip_cidr]
  }

  # HTTP — LE HTTP-01 fallback only. Caddy redirects everything else to 443.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS — UIs (OpenObserve + Keep). Admin-only at the firewall layer;
  # NO_AUTH inside Keep is acceptable because the firewall is the auth boundary.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = [var.admin_ip_cidr]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
