###############################################################################
# Grove State Backend — bootstraps the shared TF state bucket + Spaces key.
#
# What this manages:
#   - A single Spaces bucket (grove-tf-state) that holds Terraform state for
#     every OTHER env in this repo (bootstrap/, sandbox/, production/, and
#     future envs).
#   - A bucket-scoped readwrite Spaces access key for that bucket.
#   - Two GitHub Actions secrets on odoocker:
#       SPACES_ACCESS_KEY_ID, SPACES_SECRET_ACCESS_KEY
#     so workflows that use the S3 backend (terraform-drift.yml,
#     sandbox-deploy.yml, future release tooling) authenticate cleanly.
#
# Apply order in the repo:
#   1. state-backend  (this env, ONE TIME)   → creates the state bucket
#   2. bootstrap                              → uses state bucket as backend
#   3. sandbox + production + future envs    → same
#
# Destroy:
#   `prevent_destroy = true` on the bucket means `terraform destroy` will
#   refuse to wipe it. Removing the bucket requires editing this file first,
#   which is the friction we want — destroying grove-tf-state invalidates
#   the state of every other env in the repo.
###############################################################################

# === Provider configurations ===

provider "digitalocean" {
  token = var.do_token

  # Spaces creds are needed for bucket-level operations (create, refresh,
  # lifecycle). The DO REST API token can manage Spaces *keys* (via
  # digitalocean_spaces_key below) but NOT *buckets* — those go through the
  # S3-compatible protocol and need S3-style creds. We supply a long-lived
  # "plumbing" key here; the workflow-facing bucket-scoped key is created in
  # this same apply and pushed to GH secrets. See README "Why two Spaces keys".
  spaces_access_id  = var.spaces_bootstrap_access_key_id
  spaces_secret_key = var.spaces_bootstrap_secret_key
}

provider "github" {
  token = var.github_token
  owner = split("/", var.github_secrets_repo)[0]
}

# === The state bucket ===

resource "digitalocean_spaces_bucket" "tf_state" {
  name   = var.bucket_name
  region = var.region
  acl    = "private"

  # State is sacred. Versioning gives point-in-time recovery: a corrupted or
  # racing apply that clobbers a state object leaves the prior version
  # recoverable (DO Spaces retains non-current versions). This is a
  # non-destructive, in-place change — enabling it never rewrites existing
  # objects, it only starts versioning writes from here forward.
  versioning {
    enabled = true
  }

  # Keep versioning from growing without bound. Non-current state versions are
  # only needed as a short recovery window, and half-finished multipart uploads
  # (e.g. an interrupted `terraform apply`) are pure waste. State objects are
  # tiny (~KBs) so 90 days of history is cheap insurance, not bloat.
  lifecycle_rule {
    id      = "expire-noncurrent-state-versions"
    enabled = true

    noncurrent_version_expiration {
      days = 90
    }

    abort_incomplete_multipart_upload_days = 7
  }

  # Destroying this bucket destroys the state files of every other TF env
  # in this repo. Don't make it easy.
  lifecycle {
    prevent_destroy = true
  }
}

# === The bucket-scoped access key ===

# Created via DO REST API (using var.do_token) — outputs an S3-style
# access_key + secret_key that's used by Terraform's S3 backend to talk
# the actual S3-compatible protocol against nyc3.digitaloceanspaces.com.
resource "digitalocean_spaces_key" "tf_state_rw" {
  name = "${var.bucket_name}-rw"

  grant {
    bucket     = digitalocean_spaces_bucket.tf_state.name
    permission = "readwrite"
  }
}

# === Push to GitHub Actions secrets on odoocker ===

locals {
  github_repo_name = split("/", var.github_secrets_repo)[1]

  # Naming matches what odoocker workflows already read.
  # (terraform-drift.yml + sandbox-deploy.yml use these as
  #  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in their env block.)
  gh_secrets = {
    SPACES_ACCESS_KEY_ID     = digitalocean_spaces_key.tf_state_rw.access_key
    SPACES_SECRET_ACCESS_KEY = digitalocean_spaces_key.tf_state_rw.secret_key
  }
}

resource "github_actions_secret" "state_backend" {
  for_each = local.gh_secrets

  repository  = local.github_repo_name
  secret_name = each.key
  # The github provider deprecated `plaintext_value` in 6.x — `value` is the
  # new name; behavior is identical (encrypted at rest by GH, masked in logs).
  value = each.value
}
