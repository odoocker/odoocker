###############################################################################
# Grove Preview — Bootstrap (P1–P8 of the implementation plan)
#
# What this manages:
#   - P2: Spaces bucket + scoped RW access key for sanitized snapshots
#   - P3: 7-day lifecycle expiry on snapshots/ and filestore/ prefixes
#   - P4: Cloudflare → DigitalOcean NS delegation for preview.<zone>
#   - P5: SSH public key upload to DigitalOcean
#   - P6: All ten GitHub Actions secrets on the grove-sites repo
#
# What stays manual (the irreducible trust roots):
#   - P1: DigitalOcean API token (chicken-and-egg with this provider)
#   - GitHub PAT (this module uses it to write secrets)
#   - Cloudflare API token (this module uses it for DNS)
#   - Discord ops webhook URL (Discord has no clean Terraform resource)
#   - Ghost Content API keys × 3 (issued by each Ghost site's Admin UI)
#   - SSH keypair generation (must be local — putting tls_private_key in tfstate
#     leaks the private key into the state file)
#
# See README.md for the one-time setup walkthrough.
###############################################################################

# === Provider configurations ===

provider "digitalocean" {
  token = var.do_token
}

# AWS provider aliased to the DO Spaces S3 endpoint — used only for the bucket
# lifecycle configuration, which the DO provider doesn't expose natively.
provider "aws" {
  alias      = "spaces"
  region     = "us-east-1"
  access_key = digitalocean_spaces_key.preview_data_rw.access_key
  secret_key = digitalocean_spaces_key.preview_data_rw.secret_key

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "https://${var.region}.digitaloceanspaces.com"
  }

  s3_use_path_style = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "github" {
  token = var.github_token
  owner = split("/", var.github_secrets_repo)[0]
}

# === Data sources ===

data "cloudflare_zone" "grove" {
  name = var.cloudflare_zone_name
}

# === P2: Spaces bucket + scoped RW access key ===

resource "digitalocean_spaces_bucket" "preview_data" {
  name   = var.bucket_name
  region = var.region
  acl    = "private"

  # Keeping this prevents a careless `terraform destroy` from wiping seven days
  # of sanitized snapshots. Removal requires editing this file first, which is
  # the friction we want.
  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_spaces_key" "preview_data_rw" {
  name = "${var.bucket_name}-rw"

  grant {
    bucket     = digitalocean_spaces_bucket.preview_data.name
    permission = "readwrite"
  }
}

# === P3: 7-day lifecycle expiry ===

resource "aws_s3_bucket_lifecycle_configuration" "preview_data" {
  provider = aws.spaces
  bucket   = digitalocean_spaces_bucket.preview_data.name

  rule {
    id     = "expire-snapshots-${var.lifecycle_expiration_days}d"
    status = "Enabled"

    filter {
      prefix = "snapshots/"
    }

    expiration {
      days = var.lifecycle_expiration_days
    }
  }

  rule {
    id     = "expire-filestore-${var.lifecycle_expiration_days}d"
    status = "Enabled"

    filter {
      prefix = "filestore/"
    }

    expiration {
      days = var.lifecycle_expiration_days
    }
  }
}

# === P4: DNS delegation (Cloudflare → DigitalOcean) ===

resource "digitalocean_domain" "preview" {
  name = "${var.preview_subdomain}.${var.cloudflare_zone_name}"

  # Same destroy-protection reasoning as the bucket: tearing this down
  # invalidates DNS for every active preview, which is rarely intentional.
  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_record" "preview_ns" {
  for_each = toset([
    "ns1.digitalocean.com",
    "ns2.digitalocean.com",
    "ns3.digitalocean.com",
  ])

  zone_id = data.cloudflare_zone.grove.id
  name    = var.preview_subdomain
  type    = "NS"
  value   = each.value
  ttl     = 1 # 1 = automatic in Cloudflare
}

# === P5: SSH public key upload ===

resource "digitalocean_ssh_key" "preview_deploy" {
  name       = "grove-preview-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# === P6: GitHub Actions secrets ===

locals {
  # The map is the source of truth for "which secrets exist." Adding one here
  # automatically rotates / creates it in the next `terraform apply`.
  gh_secrets = {
    DIGITALOCEAN_TOKEN      = var.do_token
    DO_SPACES_ACCESS_KEY    = digitalocean_spaces_key.preview_data_rw.access_key
    DO_SPACES_SECRET_KEY    = digitalocean_spaces_key.preview_data_rw.secret_key
    ADMIN_IP_CIDR           = var.admin_ip_cidr
    DISCORD_OPS_WEBHOOK_URL = var.discord_ops_webhook
    PREVIEW_SSH_PRIVATE_KEY = file(pathexpand(var.ssh_private_key_path))
    PREVIEW_SSH_KEY_ID      = digitalocean_ssh_key.preview_deploy.fingerprint
    GHOST_KEY_GOLDBERRY     = var.ghost_key_goldberry
    GHOST_KEY_GGG           = var.ghost_key_ggg
    GHOST_KEY_NURSERY       = var.ghost_key_nursery
  }

  github_repo_name = split("/", var.github_secrets_repo)[1]
}

resource "github_actions_secret" "preview" {
  for_each = local.gh_secrets

  repository      = local.github_repo_name
  secret_name     = each.key
  plaintext_value = each.value
}
