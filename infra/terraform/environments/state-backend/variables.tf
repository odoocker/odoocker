# === Provider credentials (sensitive — set via TF_VAR_* env vars) ===
# Recommended: source from 1Password via `op run --env-file=.env.op -- make ...`
# so the values never enter shell scrollback or this repo.

variable "do_token" {
  description = "DigitalOcean API token with spaces (read, update) + spaces_key (create, read, update, delete, create_credentials) scopes. Sourced from 1Password GoldberryGrove Infra/do_token."
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub PAT with Actions:Secrets Read+Write + Metadata:Read on var.github_secrets_repo (fine-grained), or classic with `repo` scope. Sourced from 1Password GoldberryGrove Infra/github_token."
  type        = string
  sensitive   = true
}

# The DO Terraform provider's bucket resources (digitalocean_spaces_bucket and
# friends) talk the S3 protocol, not the DO REST API — so they need a Spaces
# access key for provider auth, separate from the do_token. This is "plumbing"
# credential, NOT the credential that workflows consume. See README.md section
# "Why two Spaces keys".
variable "spaces_bootstrap_access_key_id" {
  description = "Long-lived 'plumbing' Spaces access key ID used by the DO Terraform provider itself for bucket-level operations. Generate ONCE in DO Cloud Panel (Spaces Keys → All Buckets, Full Access). Distinct from the bucket-scoped workflow key this env creates. Sourced from 1Password GoldberryGrove Infra/spaces_bootstrap_access_key_id."
  type        = string
  sensitive   = true
}

variable "spaces_bootstrap_secret_key" {
  description = "Companion secret to spaces_bootstrap_access_key_id. Same lifecycle, same source. Sourced from 1Password GoldberryGrove Infra/spaces_bootstrap_secret_key."
  type        = string
  sensitive   = true
}

# === Layout (have defaults; override only if you need to) ===

variable "github_secrets_repo" {
  description = "Repo (owner/name) that receives SPACES_ACCESS_KEY_ID + SPACES_SECRET_ACCESS_KEY as GH Actions secrets."
  type        = string
  default     = "Goldberry-Playground/odoocker-goldberrygrove"
}

variable "region" {
  description = "DigitalOcean region for the state bucket. Should match the region your other envs deploy into."
  type        = string
  default     = "nyc3"
}

variable "bucket_name" {
  description = "Name of the Spaces bucket that holds Terraform remote state across all environments."
  type        = string
  default     = "grove-tf-state"
}
