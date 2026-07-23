terraform {
  required_version = ">= 1.10"

  required_providers {
    infisical = {
      source  = "Infisical/infisical"
      version = "~> 0.16"
    }
  }

  # Remote state in grove-tf-state, namespaced under `infisical-identities/`.
  # Same backend as bootstrap/preview/production/sandbox — apply order is
  # state-backend first (creates the bucket), then everything else.
  backend "s3" {
    # S3-native state locking (GOL-40): Terraform >= 1.10 writes
    # <key>.tflock via a conditional PUT (If-None-Match: *). Verified DO
    # Spaces enforces it (2nd writer gets HTTP 412). Real backend values
    # live in backend.hcl (git-ignored).
    use_lockfile = true
  }
}
