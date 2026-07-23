variable "do_token" {
  description = "DigitalOcean API token (deploy-scoped). Injected as TF_VAR_do_token via op run."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone.DNS edit + Zone.Zone read + Zone Settings edit on all four brand zones."
  type        = string
  sensitive   = true
}

variable "cloudflare_origin_ca_key" {
  description = "Cloudflare Origin CA Key (starts 'v1.0-'). Required by cloudflare_origin_ca_certificate. From CF dashboard -> API Tokens -> Origin CA Key."
  type        = string
  sensitive   = true
}

variable "spaces_access_id" {
  description = "DO Spaces access key (plumbing key, All Buckets) for the digitalocean provider's S3-protocol bucket operations AND the droplet's rclone backup uploads."
  type        = string
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "DO Spaces secret key paired with spaces_access_id."
  type        = string
  sensitive   = true
}

variable "admin_ip_cidr" {
  description = "Operator CIDR allowed SSH (e.g. 203.0.113.7/32)."
  type        = string
}

variable "healthchecks_ping_url" {
  description = "Healthchecks.io ping URL for the nightly blogs backup dead-man's switch. Empty string disables pings."
  type        = string
  default     = ""
}

variable "region" {
  description = "DO region for all production resources."
  type        = string
  default     = "nyc3"
}

variable "blogs_droplet_size" {
  description = "Blogs droplet size. 4x Ghost (~150MB each) + MySQL (~400MB) + Caddy fits in 2GB with headroom."
  type        = string
  default     = "s-2vcpu-2gb"
}

variable "droplet_image" {
  description = "Base image for droplets."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ghost_tag" {
  description = "Ghost image tag. Pin to a specific 6.x digest after first apply (Renovate bumps it)."
  type        = string
  default     = "6-alpine"
}

variable "mysql_tag" {
  description = "MySQL image tag (Ghost 6 requires MySQL 8)."
  type        = string
  default     = "8.4"
}

variable "caddy_tag" {
  description = "Official Caddy image tag. No DO-DNS plugin needed - TLS uses CF Origin CA cert files, not ACME."
  type        = string
  default     = "2-alpine"
}
