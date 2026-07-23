terraform {
  required_version = ">= 1.10"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
  }

  # Remote state in grove-tf-state, namespaced under `cloudflare-policy/`.
  # Account-wide edge policy (geo-blocking, future WAF rules) -- deliberately
  # its own env so security policy changes never ride along with app or
  # assets deploys.
  backend "s3" {
    # S3-native state locking (GOL-40): Terraform >= 1.10 writes
    # <key>.tflock via a conditional PUT (If-None-Match: *). Verified DO
    # Spaces enforces it (2nd writer gets HTTP 412). Real backend values
    # live in backend.hcl (git-ignored).
    use_lockfile = true
  }
}
