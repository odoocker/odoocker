###############################################################################
# Track 1 - Blogs droplet (Grove Production Launch spec 2026-07-04).
#
# Replaces the two hand-managed Ghost snowflakes. 4x Ghost 6 + MySQL 8 +
# Caddy; all state on a persistent volume; TLS via CF Origin CA (the four
# brand zones are Cloudflare-proxied, so the origin only ever talks to CF's
# edge - Origin CA certs are free, 15-year, and Terraform-issued: no ACME).
###############################################################################

# -- Origin CA certs (one per brand zone, covers apex + wildcard) -------------

resource "tls_private_key" "origin" {
  for_each  = local.tenants
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  for_each        = local.tenants
  private_key_pem = tls_private_key.origin[each.key].private_key_pem

  subject {
    common_name  = each.value
    organization = "Gathering at the Grove"
  }
}

resource "cloudflare_origin_ca_certificate" "origin" {
  for_each           = local.tenants
  csr                = tls_cert_request.origin[each.key].cert_request_pem
  hostnames          = [each.value, "*.${each.value}"]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

# -- Backups bucket ------------------------------------------------------------

resource "digitalocean_spaces_bucket" "blogs_backups" {
  name   = "grove-blogs-backups"
  region = var.region
  acl    = "private"

  lifecycle_rule {
    id      = "expire-dailies"
    enabled = true
    prefix  = "daily/"
    expiration {
      days = 35
    }
  }
  # monthly/ prefix has no rule - kept indefinitely.
}

# Scoped Spaces key for the droplet's rclone backups. The all-buckets
# "plumbing" key (var.spaces_access_id) stays TF-side only: it is provider
# auth for bucket ops and must never land on the droplet, where the
# metadata service exposes user_data to any process on the box. This key
# can touch ONLY the backups bucket.
resource "digitalocean_spaces_key" "blogs_backup" {
  name = "grove-blogs-backup"

  grant {
    bucket     = digitalocean_spaces_bucket.blogs_backups.name
    permission = "readwrite"
  }
}

# -- Persistent data volume ------------------------------------------------------

resource "digitalocean_volume" "blogs_data" {
  region                   = var.region
  name                     = "${var.region}-grove-prod-blogs-data"
  size                     = 20
  initial_filesystem_type  = "ext4"
  initial_filesystem_label = "blogsdata"
  tags                     = local.tags
  description              = "All blog state: MySQL data dir + 4 Ghost content dirs. Survives droplet replacement."
}

resource "digitalocean_volume_attachment" "blogs_data" {
  droplet_id = digitalocean_droplet.blogs.id
  volume_id  = digitalocean_volume.blogs_data.id
}

# -- SSH keys (same shared-key pattern as qa-l3; see qa-app-platform/main.tf) --

data "digitalocean_ssh_key" "qa_deploy" {
  name = "grove-qa-deploy"
}

data "digitalocean_ssh_key" "qa_admin" {
  name = "grove-qa-admin"
}

# -- The droplet ---------------------------------------------------------------

resource "digitalocean_droplet" "blogs" {
  name   = "grove-prod-blogs"
  size   = var.blogs_droplet_size
  image  = var.droplet_image
  region = var.region
  tags   = concat(local.tags, ["role-blogs"])

  ssh_keys = [
    data.digitalocean_ssh_key.qa_deploy.fingerprint,
    data.digitalocean_ssh_key.qa_admin.fingerprint,
  ]

  user_data = templatefile("${path.module}/cloud-init-blogs.yaml.tpl", {
    ghost_tag = var.ghost_tag
    mysql_tag = var.mysql_tag
    caddy_tag = var.caddy_tag

    # Pre-launch URL policy: the two live blogs keep their apex as Ghost's
    # canonical url (readers see no change when the apex repoints here).
    # GGG + nursery are born headless at blog.*. The launch-day flip
    # (Plan 5) moves hub+goldberry urls to blog.* too.
    ghost_urls = {
      hub       = "https://gatheringatthegrove.com"
      goldberry = "https://goldberrygrove.farm"
      ggg       = "https://blog.woodworkingeorge.com"
      nursery   = "https://blog.atthegrovenursery.com"
    }

    # Admin lives on blog.* from day one, even while the public url stays
    # the apex - Ghost otherwise redirects /ghost/ to the canonical url,
    # which pre-cutover is the OLD snowflake droplet.
    ghost_admin_urls = {
      hub       = "https://blog.gatheringatthegrove.com"
      goldberry = "https://blog.goldberrygrove.farm"
    }

    volume_name = digitalocean_volume.blogs_data.name

    origin_certs = {
      for k, z in local.tenants : z => {
        cert = cloudflare_origin_ca_certificate.origin[k].certificate
        key  = tls_private_key.origin[k].private_key_pem
      }
    }

    compose_yml_b64 = base64encode(file("${path.module}/compose/docker-compose.blogs.yml"))
    caddyfile_b64   = base64encode(file("${path.module}/compose/Caddyfile-blogs.tpl"))
    mysql_init_b64  = base64encode(file("${path.module}/compose/mysql-init.sql.tpl"))

    spaces_access_id      = digitalocean_spaces_key.blogs_backup.access_key
    spaces_secret_key     = digitalocean_spaces_key.blogs_backup.secret_key
    backups_bucket        = digitalocean_spaces_bucket.blogs_backups.name
    spaces_endpoint       = "https://${var.region}.digitaloceanspaces.com"
    healthchecks_ping_url = var.healthchecks_ping_url
  })

  # DO agent metrics not needed: Healthchecks covers backups, and synthetic
  # probes cover the public surface (obs stack, Track 2).
  monitoring = false

  timeouts {
    create = "15m"
    delete = "15m"
  }
}

# -- blog.* DNS records (all four brand zones, Cloudflare-proxied) --------------

resource "cloudflare_record" "blog" {
  for_each = local.tenants

  zone_id = data.cloudflare_zone.brand[each.key].id
  name    = "blog"
  type    = "A"
  value   = digitalocean_droplet.blogs.ipv4_address
  proxied = true
  ttl     = 1 # 1 = auto (required when proxied)
}

# -- Firewall --------------------------------------------------------------------
# 80/443 open to the world: Cloudflare proxies the public traffic, and
# locking to CF IP ranges is a hardening follow-up (needs the published
# CF ranges kept fresh - deferred; noted in the launch spec's automation
# backlog).

resource "digitalocean_firewall" "blogs" {
  name        = "grove-prod-blogs-fw"
  droplet_ids = [digitalocean_droplet.blogs.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_ip_cidr]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

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
