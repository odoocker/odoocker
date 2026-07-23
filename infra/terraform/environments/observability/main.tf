###############################################################################
# Grove Observability — dedicated obs-droplet environment.
#
# Provisions the SEPARATE observability plane from the design spec (§4–6): a
# droplet running OpenObserve + Keep, deliberately isolated from the app plane
# so monitoring outlives an app outage. OpenObserve writes Parquet to DO Spaces
# (S3-compatible) — there is no shared MinIO here (that's the app plane).
#
# Lifecycle:  `terraform apply` provisions/updates in place.
# Cost:       ~$12–24/mo (droplet) + Spaces (shared). See README.md.
#
# SCAFFOLD STATUS: fmt + validate pass, but this has NOT been `terraform apply`ed
# yet — cloud-init + cross-plane ingest + Spaces wiring need live iteration (as
# the qa env's PR history shows for the same class of work). Do not treat as
# production-ready until a clean `terraform plan` + first apply is recorded.
# Follow-ups tracked in README.md.
###############################################################################

provider "digitalocean" {
  token = var.do_token
}

locals {
  tags = [
    "env-observability",
    "project-grove",
    "plane-observability",
  ]
}

# CI key TF-manages (long-lived, per the qa env's PR #63 rationale).
resource "digitalocean_ssh_key" "obs_deploy" {
  name       = "grove-obs-deploy"
  public_key = var.ci_ssh_public_key
}

# Admin key managed out-of-band — referenced, never created/destroyed here.
data "digitalocean_ssh_key" "obs_admin" {
  name = var.admin_ssh_key_name
}

# Obs droplet via the shared droplet module (droplet + optional volume). No
# attached volume: OpenObserve Parquet lives in Spaces; Keep's SQLite is small
# and fits local disk.
module "obs_droplet" {
  source = "../../modules/droplet"

  name           = "grove-obs"
  size           = var.droplet_size
  region         = var.region
  image          = var.droplet_image
  volume_size_gb = 0
  monitoring     = true
  tags           = local.tags

  ssh_key_ids = [
    digitalocean_ssh_key.obs_deploy.fingerprint,
    data.digitalocean_ssh_key.obs_admin.fingerprint,
  ]

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tpl", {
    openobserve_tag           = var.openobserve_tag
    keep_tag                  = var.keep_tag
    openobserve_root_email    = var.openobserve_root_email
    openobserve_root_password = var.openobserve_root_password
    spaces_endpoint           = var.spaces_endpoint
    spaces_bucket             = var.spaces_bucket
    spaces_access_key         = var.spaces_access_key
    spaces_secret_key         = var.spaces_secret_key
    keep_webhook_token        = var.keep_webhook_token
    cost_env                  = var.cost_env
    # base64 the compose so cloud-init's YAML parser never sees its content
    # (same technique the qa env uses for its compose/Caddyfile).
    compose_obs_b64 = base64encode(file("${path.module}/compose/docker-compose.obs.yml"))
  })
}

# ── Firewall ──────────────────────────────────────────────────────────────
# UIs (5080 OpenObserve, 3034 Keep) + SSH are admin-only. OTLP ingest from the
# app-plane runners (synthetic-runner, cost-bridge) is admin-scoped for now;
# TODO(live): add the app droplet's IP (or a DO VPC) as an ingest source, and
# front OpenObserve ingest with the Cloudflare-WAF Bearer endpoint (spec §1)
# for the off-droplet GitHub Actions Playwright/Hurl crons.
resource "digitalocean_firewall" "obs" {
  name        = "grove-obs-fw"
  droplet_ids = [module.obs_droplet.droplet_id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_ip_cidr]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "5080" # OpenObserve UI + OTLP ingest
    source_addresses = [var.admin_ip_cidr]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "3034" # Keep UI
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
