# ── PR identity (provided by the preview-up workflow) ──────────────────────

variable "pr_number" {
  description = "Pull request number — drives droplet name, DNS host, TF state key."
  type        = number

  validation {
    condition     = var.pr_number > 0
    error_message = "pr_number must be a positive integer."
  }
}

variable "pr_branch" {
  description = "Branch name of the PR (for tagging and DO console legibility)."
  type        = string
}

# ── Images (resolved by the workflow from the PR's HEAD SHA) ───────────────

variable "frontend_image_tags" {
  description = "Image tag per frontend tenant. Keys: hub, goldberry, ggg, nursery. Values look like `pr-104-deadbeef` or `latest` for manual smoke."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["hub", "goldberry", "ggg", "nursery"] : contains(keys(var.frontend_image_tags), k)])
    error_message = "frontend_image_tags must include keys: hub, goldberry, ggg, nursery."
  }
}

variable "odoo_image_tag" {
  description = "Image tag for the grove-odoo image (ghcr.io/goldberry-playground/grove-odoo:<tag>). Until the Odoo image CI task lands (Asana gid 1215643893837105), use `latest` from an existing manual build or the base `odoo:19` if no custom image yet."
  type        = string
}

variable "snapshot_date" {
  description = "ISO date (YYYY-MM-DD) of the sanitized snapshot to restore from. Resolved by CI from the heartbeat file in the snapshots bucket."
  type        = string
}

# ── Credentials (sensitive — set via TF_VAR_* env vars or op run) ──────────

variable "do_token" {
  description = "DigitalOcean API token. Used by the provider for droplet/DNS/firewall ops, and templated into cloud-init for Caddy's DNS-01 challenge."
  type        = string
  sensitive   = true
}

variable "spaces_access_key" {
  description = "DO Spaces access key — must have read access to grove-preview-data (for snapshot pulls inside cloud-init). Typically the same key state-backend/ provisioned for grove-tf-state, scoped wider."
  type        = string
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "Companion secret to spaces_access_key."
  type        = string
  sensitive   = true
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of the SSH key registered with DO (from pre-flight P5). Operators use this to ssh root@<droplet_ip> for debugging."
  type        = string
}

variable "admin_ip_cidr" {
  description = "CIDR for SSH allowlist (port 22). Single CIDR — for a wider range, add more inbound_rules in main.tf."
  type        = string
}

variable "ghost_content_keys" {
  description = "Prod Ghost Content API keys per tenant. Keys: goldberry, ggg, nursery. Read-only by design — safe to use in previews against the real prod Ghost."
  type        = map(string)
  sensitive   = true

  validation {
    condition     = alltrue([for k in ["goldberry", "ggg", "nursery"] : contains(keys(var.ghost_content_keys), k)])
    error_message = "ghost_content_keys must include keys: goldberry, ggg, nursery."
  }
}

# ── Layout (defaults are usually right) ────────────────────────────────────

variable "region" {
  description = "DO region. Co-locate with grove-preview-data (nyc3) to avoid Spaces egress."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "Droplet size slug. s-2vcpu-4gb fits the full preview Compose stack (postgres + odoo + 4 frontends + caddy) for the ≤24h preview lifetime."
  type        = string
  default     = "s-2vcpu-4gb"
}
