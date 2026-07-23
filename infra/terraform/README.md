# Grove Terraform Infrastructure

## Directory Layout

```
infra/terraform/
├── modules/
│   └── droplet/          # Reusable Droplet + volume module
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── sandbox/           # Ephemeral QA Droplet (auto-destroy tag)
    │   ├── versions.tf
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   ├── cloud-init.yaml
    │   ├── backend.hcl.example
    │   └── terraform.tfvars.example
    └── production/        # Persistent prod + monitoring Droplets
        ├── versions.tf
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── backend.hcl.example
        └── terraform.tfvars.example
```

## Module: `modules/droplet`

Creates a `digitalocean_droplet` + `digitalocean_volume` + `digitalocean_volume_attachment`.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | — | Droplet name |
| `size` | string | — | Droplet slug |
| `region` | string | — | DO region |
| `image` | string | `ubuntu-24-04-x64` | OS image |
| `ssh_key_ids` | list(string) | — | SSH key fingerprints |
| `volume_size_gb` | number | — | Volume size (GiB) |
| `tags` | list(string) | `[]` | DO tags |
| `cloud_init` | string | `""` | cloud-config user_data |
| `monitoring` | bool | `false` | Enable DO monitoring agent |

Outputs: `droplet_id`, `ipv4_address`, `volume_id`.

## State Organization

Remote state is stored in DigitalOcean Spaces (`grove-tf-state` bucket, nyc3):

| Environment | State key |
|-------------|-----------|
| sandbox | `sandbox/terraform.tfstate` |
| production | `production/terraform.tfstate` |

## Naming Convention

| Resource | Pattern | Example |
|----------|---------|---------|
| Droplet | `grove-{env}[-{role}]` | `grove-sandbox`, `grove-production-app` |
| Volume | `{droplet-name}-data` | `grove-sandbox-data` |
| Firewall | `grove-{env}-{role}` | `grove-production-app` |

## Required Terraform Version

Terraform >= 1.6. Provider: `digitalocean/digitalocean ~> 2.40`.

## DNS

DNS records are managed in **Cloudflare**, not DigitalOcean. Terraform code intentionally does NOT manage A records — they must be created and maintained manually in Cloudflare.

**Production A records** (point at `production_droplet_ip` from Terraform output):

- `gatheringatthegrove.com` (and `www.gatheringatthegrove.com`)
- `goldberrygrove.farm` (and `www.goldberrygrove.farm`)
- `woodworkingeorge.com` (and `www.woodworkingeorge.com`)
- `atthegrovenursery.com` (and `www.atthegrovenursery.com`)
- `erp.gatheringatthegrove.com`
- `blog.goldberrygrove.farm`
- `blog.woodworkingeorge.com`
- `blog.atthegrovenursery.com`

**Monitoring A records** (point at `monitoring_droplet_ip` from Terraform output):

- `grafana.gatheringatthegrove.com`
- `status.gatheringatthegrove.com`

## Usage

See `docs/DEPLOY.md` for the full walkthrough.

```bash
# Sandbox
make tf-init env=sandbox
make tf-plan env=sandbox
make tf-apply env=sandbox

# Production (requires CONFIRM=yes guard)
make tf-apply env=production CONFIRM=yes
```
