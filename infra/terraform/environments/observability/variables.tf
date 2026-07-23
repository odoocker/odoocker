variable "do_token" {
  description = "DigitalOcean API token (droplet/volume/firewall write)."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "Obs droplet slug. s-2vcpu-4gb comfortably runs OpenObserve + Keep (+ Plausible in prod)."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "droplet_image" {
  description = "Droplet OS image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ci_ssh_public_key" {
  description = "Long-lived CI SSH public key registered on the obs droplet (same pattern as the qa env)."
  type        = string
}

variable "admin_ssh_key_name" {
  description = "Name of the out-of-band admin SSH key already present in DO (referenced, never managed)."
  type        = string
  default     = "grove-qa-admin"
}

variable "admin_ip_cidr" {
  description = "CIDR allowed to reach SSH (22) and the OpenObserve/Keep UIs (5080/3034). Never 0.0.0.0/0 in a real tfvars."
  type        = string
}

# ── Observability stack config (flows into cloud-init → .env.monitoring) ──────
variable "openobserve_tag" {
  description = "OpenObserve image tag (pin; promoted via the release manifest once it exists)."
  type        = string
  default     = "v0.17.2"
}

variable "keep_tag" {
  description = "Keep image tag."
  type        = string
  default     = "latest"
}

variable "openobserve_root_email" {
  description = "OpenObserve root user email."
  type        = string
}

variable "openobserve_root_password" {
  description = "OpenObserve root user password."
  type        = string
  sensitive   = true
}

# OpenObserve Parquet storage on the standalone obs droplet targets DO Spaces
# (S3-compatible) — there is no shared MinIO here (that's the app plane).
variable "spaces_endpoint" {
  description = "DO Spaces S3 endpoint for OpenObserve Parquet storage."
  type        = string
  default     = "https://nyc3.digitaloceanspaces.com"
}

variable "spaces_bucket" {
  description = "DO Spaces bucket name for OpenObserve data."
  type        = string
}

variable "spaces_access_key" {
  description = "DO Spaces access key (S3 creds)."
  type        = string
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "DO Spaces secret key (S3 creds)."
  type        = string
  sensitive   = true
}

variable "discord_webhook_warning" {
  description = "Discord webhook URL for warning alerts (Keep provider)."
  type        = string
  sensitive   = true
}

variable "discord_webhook_critical" {
  description = "Discord webhook URL for critical alerts (Keep provider)."
  type        = string
  sensitive   = true
}

variable "keep_webhook_token" {
  description = "Keep webhook token (OpenObserve→Keep auth). Generate: openssl rand -hex 32."
  type        = string
  sensitive   = true
}

variable "cost_env" {
  description = "Env label stamped on cost + synthetic metrics (qa|prod)."
  type        = string
  default     = "prod"
}
