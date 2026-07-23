terraform {
  required_version = ">= 1.10"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state in grove-tf-state, namespaced under `production/`.
  backend "s3" {
    # S3-native state locking (GOL-40): Terraform >= 1.10 writes
    # <key>.tflock via a conditional PUT (If-None-Match: *). Verified DO
    # Spaces enforces it (2nd writer gets HTTP 412). Real backend values
    # live in backend.hcl (git-ignored). See backend.hcl.example.
    use_lockfile = true
  }
}
