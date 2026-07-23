terraform {
  required_version = ">= 1.10"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
  }

  backend "s3" {
    # DigitalOcean Spaces is S3-compatible. Real values live in backend.hcl
    # (git-ignored). See backend.hcl.example for the template.
    #
    # S3-native state locking (GOL-40): TF >= 1.10 writes <key>.tflock via
    # a conditional PUT (If-None-Match); verified DO Spaces enforces it (412).
    use_lockfile = true
  }
}

provider "digitalocean" {
  # Token read from DIGITALOCEAN_TOKEN env var (set in CI via secrets).
  # Spaces credentials are read from SPACES_ACCESS_KEY_ID and
  # SPACES_SECRET_ACCESS_KEY for the S3 backend.
}
