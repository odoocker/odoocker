terraform {
  required_version = ">= 1.10"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Per-PR state isolation — the workflow (Task 3.3) templates `key` as
  # `preview/pr-<number>.tfstate` so multiple PRs can be in flight without
  # state collisions. backend.hcl is git-ignored; see backend.hcl.example.
  backend "s3" {
    # S3-native state locking (GOL-40): Terraform >= 1.10 writes
    # <key>.tflock via a conditional PUT (If-None-Match: *). Verified DO
    # Spaces enforces it (2nd writer gets HTTP 412). Real backend values
    # live in backend.hcl (git-ignored).
    use_lockfile = true
  }
}

provider "digitalocean" {
  token = var.do_token

  # Spaces creds are needed because the snapshot-restore step inside
  # cloud-init pulls from grove-preview-data (S3-compatible). The
  # provider doesn't *use* them for bucket operations here (we don't
  # create buckets in this env), but we hand them off via templatefile()
  # into the cloud-init script.
  spaces_access_id  = var.spaces_access_key
  spaces_secret_key = var.spaces_secret_key
}
