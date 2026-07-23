variable "name" {
  description = "Name of the Droplet"
  type        = string
}

variable "size" {
  description = "Droplet slug (e.g. s-4vcpu-8gb)"
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug"
  type        = string
}

variable "image" {
  description = "Droplet OS image slug or ID"
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ssh_key_ids" {
  description = "List of SSH key fingerprints or IDs to provision on the Droplet"
  type        = list(string)
}

variable "volume_size_gb" {
  description = "Size of the attached block volume in GiB. Set to 0 to skip volume creation entirely (droplet uses local disk only)."
  type        = number
  default     = 0

  validation {
    condition     = var.volume_size_gb >= 0
    error_message = "volume_size_gb must be 0 or positive."
  }
}

variable "tags" {
  description = "List of tag names to apply to the Droplet and volume"
  type        = list(string)
  default     = []
}

variable "cloud_init" {
  description = "cloud-config YAML passed as user_data"
  type        = string
  default     = ""
}

variable "monitoring" {
  description = "Enable DigitalOcean agent-based monitoring"
  type        = bool
  default     = false
}

variable "admin_cidr" {
  description = "CIDR block allowed to reach SSH (port 22). Defaults to 0.0.0.0/0 ONLY in example files — never accept that default in real terraform.tfvars."
  type        = string
  default     = "0.0.0.0/0"
}
