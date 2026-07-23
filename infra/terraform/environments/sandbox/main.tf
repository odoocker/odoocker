locals {
  env  = "sandbox"
  name = "grove-${local.env}"

  cloud_init = templatefile("${path.module}/cloud-init.yaml", {
    git_sha  = var.git_sha
    repo_url = var.repo_url
  })

  tags = [
    "env-sandbox",
    "auto-destroy",
    "sha-${var.git_sha}",
    "project-grove",
  ]
}

module "sandbox" {
  source = "../../modules/droplet"

  name           = local.name
  size           = "s-4vcpu-8gb"
  region         = var.region
  image          = "ubuntu-24-04-x64"
  ssh_key_ids    = var.ssh_key_ids
  volume_size_gb = 50
  tags           = local.tags
  cloud_init     = local.cloud_init
  monitoring     = true
}
