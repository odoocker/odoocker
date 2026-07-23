terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
  }
}

resource "digitalocean_droplet" "this" {
  name       = var.name
  size       = var.size
  region     = var.region
  image      = var.image
  ssh_keys   = var.ssh_key_ids
  monitoring = var.monitoring
  user_data  = var.cloud_init != "" ? var.cloud_init : null
  tags       = var.tags

  # Wait for the Droplet to be fully provisioned before Terraform considers
  # the resource created. This prevents the volume attachment from racing
  # against a still-booting instance.
  lifecycle {
    create_before_destroy = false
  }
}

resource "digitalocean_volume" "this" {
  count                    = var.volume_size_gb > 0 ? 1 : 0
  name                     = "${var.name}-data"
  region                   = var.region
  size                     = var.volume_size_gb
  initial_filesystem_type  = "ext4"
  initial_filesystem_label = "data"
  tags                     = var.tags
}

resource "digitalocean_volume_attachment" "this" {
  count      = var.volume_size_gb > 0 ? 1 : 0
  droplet_id = digitalocean_droplet.this.id
  volume_id  = digitalocean_volume.this[0].id
}
