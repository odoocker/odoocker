###############################################################################
# Grove Preview — per-PR droplet TF env
#
# What this manages, per PR:
#   - One DigitalOcean droplet running the full preview Compose stack
#     (Caddy + postgres + odoo + hub + goldberry + ggg + nursery).
#   - DNS A record for an unguessable host label (pr-<number>-<5char>) in
#     the preview.gatheringatthegrove.com zone, plus 5 tenant CNAMEs.
#   - A firewall scoping SSH to the operator's IP and 80/443 to anywhere.
#
# Lifecycle:
#   `terraform apply`  — preview-up.yml runs this on `qa`-labeled PRs.
#   `terraform destroy` — preview-down.yml runs this on PR close.
#   Cost while up: ~$0.033/hr (s-2vcpu-4gb in nyc3, no volume per Task 2.1).
#
# This env uses LOCAL DISK ONLY (volume_size_gb = 0 via the optional-volume
# refactor in the droplet module, PR #31). Previews are ephemeral; the
# sanitized snapshot fits in the droplet's local disk for ≤24h.
###############################################################################

locals {
  env  = "preview"
  name = "grove-preview-pr-${var.pr_number}"

  tags = [
    "env-preview",
    "auto-destroy-7d", # consumed by preview-sweep.yml (Task 3.7)
    "pr-${var.pr_number}",
    "project-grove",
  ]

  # DNS zone is the delegated subdomain — preview pipeline bootstrap (PR #19
  # in odoocker, merged) configured Cloudflare → DigitalOcean NS delegation
  # for this zone.
  preview_zone = "preview.gatheringatthegrove.com"
}

# A 5-char random suffix appended to the host label so the URL is
# unguessable (cuts down on opportunistic scanning + drive-by indexing).
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
  lower   = true
}

locals {
  # e.g. pr-104-x7q2k
  preview_host = "pr-${var.pr_number}-${random_string.suffix.result}"

  # Templated cloud-init carries everything the droplet needs to bring up
  # the stack on first boot: docker install, ghcr login, snapshot restore,
  # `docker compose up`. See cloud-init.yaml.tpl for the full script.
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tpl", {
    pr_number           = var.pr_number
    preview_host        = local.preview_host
    odoo_image_tag      = var.odoo_image_tag
    frontend_image_tags = var.frontend_image_tags
    snapshot_date       = var.snapshot_date
    spaces_access_key   = var.spaces_access_key
    spaces_secret_key   = var.spaces_secret_key
    ghost_content_keys  = var.ghost_content_keys
    do_token_for_caddy  = var.do_token # for Caddy's DO DNS-01 challenge
    compose_yml         = file("${path.module}/compose/docker-compose.preview.yml")
    caddyfile_tpl       = file("${path.module}/compose/Caddyfile.tpl")
  })
}

# ── The droplet itself (no volume — local disk only) ───────────────────────

module "droplet" {
  source = "../../modules/droplet"

  name           = local.name
  size           = var.droplet_size
  region         = var.region
  image          = "ubuntu-24-04-x64"
  ssh_key_ids    = [var.ssh_key_fingerprint]
  volume_size_gb = 0 # local disk only — previews are ephemeral
  tags           = local.tags
  cloud_init     = local.cloud_init
  monitoring     = false # cost optimization; previews are short-lived
}

# ── DNS records inside the delegated preview zone ──────────────────────────

# Apex A record for the preview host — `pr-104-x7q2k.preview.gatheringatthegrove.com`.
resource "digitalocean_record" "preview_apex" {
  domain = local.preview_zone
  type   = "A"
  name   = local.preview_host
  value  = module.droplet.ipv4_address
  ttl    = 300 # 5 min — preview lifetimes are short; low TTL helps cleanup
}

# Per-tenant CNAMEs that resolve to the apex above.
# Caddy on the droplet routes by Host header (see Caddyfile.tpl).
resource "digitalocean_record" "tenant" {
  for_each = toset(["hub", "goldberry", "ggg", "nursery", "odoo"])

  domain = local.preview_zone
  type   = "CNAME"
  name   = "${each.key}.${local.preview_host}"
  value  = "${local.preview_host}.${local.preview_zone}." # trailing dot — FQDN
  ttl    = 300
}

# ── Firewall ──────────────────────────────────────────────────────────────

resource "digitalocean_firewall" "preview" {
  name = "${local.name}-fw"

  droplet_ids = [module.droplet.droplet_id]

  # SSH — scoped to the operator
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_ip_cidr]
  }

  # HTTP — Caddy listens here for ACME HTTP-01 (fallback) + redirects to 443
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS — the public surface
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound: everything (apt, ghcr pull, snapshot pull, Caddy DNS-01, etc.)
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
