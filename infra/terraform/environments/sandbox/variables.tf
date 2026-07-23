variable "git_sha" {
  description = "Full Git SHA of the commit being deployed. Used to tag the Droplet for traceability."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug for the sandbox Droplet"
  type        = string
  default     = "nyc3"
}

variable "ssh_key_ids" {
  description = "List of DigitalOcean SSH key fingerprints or numeric IDs to provision on the Droplet"
  type        = list(string)
}

variable "repo_url" {
  description = "GitHub clone URL for the application repository"
  type        = string
  default     = "https://github.com/Goldberry-Playground/odoocker-goldberrygrove.git"
}
