###############################################################################
# Grove QA — Level 3 (ADR-007): App Platform for frontends, Managed Postgres,
# tiny Odoo droplet. This file scaffolds Phase 1: the bones (Managed PG +
# Odoo droplet + Caddy + DNS + firewall). Phases 2-5 add the App Platform
# apps, validate, cut over, decommission.
#
# Distinct from the monolith QA env (`environments/qa/`) which keeps running
# in parallel until DNS cutover (ADR-007 D4 parallel-cutover sequencing).
#
# Per ADR-007 D6 budget: ~$47/mo total while running.
#   - Managed PG dev tier: ~$15/mo
#   - Odoo droplet s-1vcpu-2gb: ~$12/mo
#   - Caddy /data volume: ~$0.10/mo
#   - 4 App Platform basic apps (Phase 2): ~$20/mo
#
# What this env manages (Phase 1 only — App Platform apps + obs droplet
# arrive in later phases):
#   1. Cloudflare → DO NS delegation for qa-l3.gatheringatthegrove.com
#   2. DO domain + DNS records under the qa-l3 zone
#   3. DO SSH keys (long-lived; same pattern as monolith QA)
#   4. DO Managed Postgres cluster (dev tier, private network)
#   5. DO droplet (Ubuntu 24.04, s-1vcpu-2gb) for Odoo + Caddy only
#   6. DO firewall for the Odoo droplet
#   7. DO persistent volume for Caddy /data (LE cert persistence — same
#      pattern as ADR-005 PR-A in the monolith env)
#   8. Trusted-sources allowlist on the Managed PG cluster (Odoo droplet
#      + operator CIDR; no public exposure)
###############################################################################

provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  qa_zone = "${var.qa_subdomain}.${var.cloudflare_zone_name}"
  tags = [
    "env-qa-l3",
    "project-grove",
    "layer-app-platform",
  ]
}

data "cloudflare_zone" "apex" {
  name = var.cloudflare_zone_name
}

# ── Cloudflare → DigitalOcean NS delegation for qa-l3.<apex> ────────────────
# Same delegation pattern as monolith QA (environments/qa/main.tf) — three
# NS records under the apex Cloudflare zone hand DNS for the qa-l3
# subdomain over to DO's nameservers.

resource "cloudflare_record" "qa_ns" {
  for_each = toset([
    "ns1.digitalocean.com",
    "ns2.digitalocean.com",
    "ns3.digitalocean.com",
  ])

  zone_id = data.cloudflare_zone.apex.id
  name    = var.qa_subdomain
  type    = "NS"
  value   = each.value
  ttl     = 1 # 1 = Cloudflare "Auto"
}

# ── DO domain (the delegated zone DO now manages) ───────────────────────────

resource "digitalocean_domain" "qa" {
  name = local.qa_zone
}

# ── SSH keys ────────────────────────────────────────────────────────────────
# Same two-key pattern as monolith QA (one TF-managed CI key, one
# out-of-band admin key). See environments/qa/main.tf for the full rationale
# on long-lived vs ephemeral.

## CI SSH key — SHARED with the monolith QA env.
#
# Rationale (learned via 2026-06-30 first-apply failure): DO's API enforces
# uniqueness on SSH KEY CONTENT (fingerprint), not name. The monolith QA env
# already uploaded this public key as `grove-qa-deploy`. Trying to add the
# SAME key material under a different name (`grove-qa-l3-deploy`) returns
# `422 SSH Key is already in use on your account`.
#
# Options considered:
#   (a) Generate a new keypair for Level 3 -- adds a secret to 1P + Infisical
#       for zero benefit (both envs share the same operator workflow).
#   (b) Reference the monolith's key via data source -- SAME key, SAME
#       fingerprint, SAME private key on the runner. No new secret needed.
#
# Went with (b) -- var.ci_ssh_public_key's description ALREADY says "same
# key as monolith", so this aligns with the stated intent.
#
# NOTE: var.ci_ssh_public_key becomes vestigial here (kept for backward
# compatibility with existing tfvars). The default value matches the
# monolith's key so no operator workflow changes.
data "digitalocean_ssh_key" "qa_deploy" {
  name = "grove-qa-deploy"
}

# qa_admin is managed OUT OF BAND. TF references via data source so it's
# never created/destroyed/replaced here. To rotate: replace the DO SSH key
# named "grove-qa-admin" via DO UI, then re-apply (data source picks up
# the new fingerprint, droplet's ssh_keys list updates in place).
data "digitalocean_ssh_key" "qa_admin" {
  name = "grove-qa-admin"
}

# ── Managed Postgres ────────────────────────────────────────────────────────
# The core architectural shift of Level 3: Postgres leaves the droplet
# entirely. Connects via private network from the Odoo droplet (same VPC
# region). Cost: ~$15/mo for dev tier; ~$30/mo prod tier (basic + backups).
#
# Per ADR-007 D3: backups + PITR + private network are the value props.
# Odoo connects via DATABASE_URL — trivial swap from current docker-compose
# `postgres` service name. The cloud-init template wires this into the
# `odoo` container's env block.

resource "digitalocean_database_cluster" "pg" {
  name       = "grove-qa-l3-pg"
  engine     = "pg"
  version    = var.pg_version
  size       = var.pg_size
  region     = var.region
  node_count = var.pg_node_count
  tags       = local.tags

  # Dev tier doesn't support multi-day backup windows; the cluster gets
  # 1 day of automatic backups regardless. Production (D6, separate env)
  # would set this on the basic-tier cluster.
}

# Odoo-side DB + DB user. These are managed via TF (instead of via the
# default postgres user) so Odoo gets least-privilege creds and the
# Managed PG cluster's primary admin password stays out of the droplet.

resource "digitalocean_database_db" "odoo" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "odoo"
}

resource "digitalocean_database_user" "odoo" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "odoo"
  # MySQL-style password authentication is the default for PG too;
  # SCRAM-SHA-256 is enforced server-side regardless.
}

# Trusted-sources allowlist: lock the Managed PG cluster to the Odoo
# droplet's IP + the operator CIDR. Without this the cluster is publicly
# reachable on its assigned hostname (firewalled but exposed). With this,
# the cluster only accepts connections from the listed sources.
#
# Note: trusted sources work alongside private networking — the Odoo
# droplet connects over private IP (which is itself implicitly allowed),
# but listing the droplet here makes the intent explicit and forces TF
# to recreate the firewall rule if the droplet is recreated.
resource "digitalocean_database_firewall" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id

  rule {
    type  = "droplet"
    value = digitalocean_droplet.odoo.id
  }

  rule {
    type  = "ip_addr"
    value = split("/", var.admin_ip_cidr)[0]
  }
}

# ── Persistent Caddy /data volume ───────────────────────────────────────────
# Same pattern as monolith QA env (environments/qa/main.tf line 159+):
# persist Caddy's LE account key + issued certs across droplet recreates so
# we don't burn rate-limit budget on iterative cycles. Cost: ~$0.10/mo.
#
# In Level 3 this matters MUCH less because Caddy fronts ONLY Odoo (one
# hostname, one cert). The 5-identifier rate-limit class from the monolith
# is gone. But keeping the volume gives us cert continuity across droplet
# replacements anyway — cheap insurance.

resource "digitalocean_volume" "caddy_data" {
  region                   = var.region
  name                     = "${var.region}-grove-qa-l3-caddy-data"
  size                     = 1
  initial_filesystem_type  = "ext4"
  initial_filesystem_label = "data"
  tags                     = local.tags
  description              = "Persistent Caddy /data for the Level 3 Odoo droplet. Survives droplet teardown. ~$0.10/mo."
}

resource "digitalocean_volume_attachment" "caddy_data" {
  droplet_id = digitalocean_droplet.odoo.id
  volume_id  = digitalocean_volume.caddy_data.id
}

# ── Odoo droplet ────────────────────────────────────────────────────────────
# Tiny droplet running ONLY Odoo + Caddy. Postgres is offloaded to Managed
# PG (above); frontends move to App Platform (Phase 2). This is the only
# stateful compute Level 3 keeps on a droplet — Odoo's filestore + workers +
# custom modules + odoorc.sh runtime substitution don't fit App Platform's
# stateless container model.

resource "digitalocean_droplet" "odoo" {
  name   = "grove-qa-l3-odoo"
  size   = var.odoo_droplet_size
  image  = var.droplet_image
  region = var.region
  tags   = local.tags

  ssh_keys = [
    data.digitalocean_ssh_key.qa_deploy.fingerprint,
    data.digitalocean_ssh_key.qa_admin.fingerprint,
  ]

  user_data = templatefile("${path.module}/cloud-init.yaml.tpl", {
    qa_zone         = local.qa_zone
    odoo_image_tag  = var.odoo_image_tag
    caddy_image_tag = var.caddy_image_tag

    # Managed PG connection params. Odoo reads these via DB_HOST/DB_PORT/
    # DB_USER/DB_PASSWORD env vars (entrypoint.sh + odoorc.sh substitute
    # them into /etc/odoo/odoo.conf).
    pg_host     = digitalocean_database_cluster.pg.private_host
    pg_port     = digitalocean_database_cluster.pg.port
    pg_database = digitalocean_database_db.odoo.name
    pg_user     = digitalocean_database_user.odoo.name
    pg_password = digitalocean_database_user.odoo.password

    # DO API token for Caddy's DNS-01 ACME challenge (single hostname now,
    # but DNS-01 still required to issue without port-80 dance).
    do_token_for_caddy = var.do_token
    acme_endpoint      = var.acme_endpoint

    # base64-encode embedded files (ADR-005 PR-B pattern — bypasses cloud-init
    # YAML parser entirely for content with awkward characters).
    compose_yml_b64   = base64encode(file("${path.module}/compose/docker-compose.qa.yml"))
    caddyfile_tpl_b64 = base64encode(replace(file("${path.module}/compose/Caddyfile.tpl"), "$${QA_ZONE}", local.qa_zone))
  })

  monitoring = false

  # Same delete-timeout bump as monolith QA (PR #117 era). DO API droplet
  # delete can hang past the provider's default 60s context deadline.
  timeouts {
    create = "15m"
    delete = "15m"
  }
}

# ── DNS records inside the delegated qa-l3 zone ─────────────────────────────
#
# PHASE 1 SCOPE: only the Odoo hostname (odoo.qa-l3.<apex>) and the apex
# A record (qa-l3.<apex>, currently pointing at the Odoo droplet as a
# placeholder for the hub). The 4 frontend CNAMEs (goldberry, ggg, nursery,
# hub at apex) come in Phase 2 alongside the digitalocean_app resources —
# they need App Platform's default URL as their CNAME target, which
# doesn't exist yet.

# Apex of the delegated zone — placeholder pointing at Odoo droplet. In
# Phase 2 this becomes a CNAME to the hub App Platform's default URL.
resource "digitalocean_record" "qa_apex" {
  domain = digitalocean_domain.qa.name
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.odoo.ipv4_address
  ttl    = 300
}

# Odoo hostname — odoo.qa-l3.gatheringatthegrove.com → Odoo droplet.
# This URL is the canonical entrypoint for Odoo's web UI + the headless
# API endpoint consumed by App Platform frontends (cross-environment).
resource "digitalocean_record" "odoo" {
  domain = digitalocean_domain.qa.name
  type   = "A"
  name   = "odoo"
  value  = digitalocean_droplet.odoo.ipv4_address
  ttl    = 300
}

# ── Firewall (Odoo droplet) ─────────────────────────────────────────────────

resource "digitalocean_firewall" "odoo" {
  name        = "grove-qa-l3-odoo-fw"
  droplet_ids = [digitalocean_droplet.odoo.id]

  # SSH — operator only
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_ip_cidr]
  }

  # HTTP — Caddy redirects 80 → 443. DNS-01 ACME means port 80 is NOT
  # load-bearing for cert issuance; open here only for browsers that
  # hit http:// out of habit.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS — public Odoo surface (web UI + REST API for App Platform apps).
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
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
